// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPolicyPool} from '../interfaces/IPolicyPool.sol';
import {IRiskModule} from '../interfaces/IRiskModule.sol';
import {IEToken} from '../interfaces/IEToken.sol';
import {Policy} from './Policy.sol';
import {WadRayMath} from './WadRayMath.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {DataTypes} from './DataTypes.sol';

contract PolicyPool is IPolicyPool, ERC721, ERC721Enumerable, Pausable, AccessControl {
  using EnumerableSet for EnumerableSet.AddressSet;
  using WadRayMath for uint256;
  using SafeERC20 for IERC20;
  using Policy for Policy.PolicyData;
  using DataTypes for DataTypes.ETokenToWadMap;

  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 public constant ENSURO_DAO_ROLE = keccak256("ENSURO_DAO_ROLE");
  bytes32 public constant REBALANCE_ROLE = keccak256("REBALANCE_ROLE");

  uint256 public constant MAX_ETOKENS = 10;

  IERC20 internal _currency;

  EnumerableSet.AddressSet internal _riskModules;
  mapping (IRiskModule => RiskModuleStatus) internal _riskModuleStatus;

  EnumerableSet.AddressSet internal _eTokens;
  mapping (IEToken => ETokenStatus) internal _eTokenStatus;

  mapping (uint256 => Policy.PolicyData) internal _policies;
  mapping (uint256 => DataTypes.ETokenToWadMap) internal _policiesFunds;
  uint256 internal _policyCount;   // Growing id for policies

  uint256 internal _activePremiums;    // sum of premiums of active policies - In Wad
  uint256 internal _activePurePremiums;    // sum of pure-premiums of active policies - In Wad
  uint256 internal _borrowedActivePP;    // amount borrowed from active pure premiums to pay defaulted policies
  uint256 internal _wonPurePremiums;     // amount of pure premiums won from non-defaulted policies

  address internal _treasury;            // address of Ensuro treasury
  address internal _assetManager;        // asset manager (TBD)

  modifier onlyAssetManager {
    require(_msgSender() == _assetManager, "Only assetManager can call this function");
    _;
  }

  constructor(
    string memory name_,
    string memory symbol_,
    IERC20 curreny_,
    address treasury_,
    address assetManager_

  ) ERC721(name_, symbol_) {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _setupRole(PAUSER_ROLE, msg.sender);
    _currency = curreny_;
    /*
    _policyCount = 0;
    _activePurePremiums = 0;
    _activePremiums = 0;
    _borrowedActivePP = 0;
    _wonPurePremiums = 0;
    */
    _treasury = treasury_;
    _assetManager = assetManager_;
  }

  function pause() public {
    require(hasRole(PAUSER_ROLE, msg.sender));
    _pause();
  }

  function unpause() public {
    require(hasRole(PAUSER_ROLE, msg.sender));
    _unpause();
  }

  function _beforeTokenTransfer(address from, address to, uint256 tokenId)
    internal
    whenNotPaused
    override(ERC721, ERC721Enumerable)
  {
    super._beforeTokenTransfer(from, to, tokenId);
  }

  function supportsInterface(bytes4 interfaceId)
    public
    view
    override(ERC721, ERC721Enumerable, AccessControl)
    returns (bool)
  {
    return super.supportsInterface(interfaceId);
  }

  function currency() external view virtual override returns (IERC20) {
    return _currency;
  }

  function purePremiums() external view returns (uint256) {
    return _activePurePremiums + _wonPurePremiums - _borrowedActivePP;
  }

  function addRiskModule(IRiskModule riskModule) external onlyRole(ENSURO_DAO_ROLE) {
    require(!_riskModules.contains(address(riskModule)), "Risk Module already in the pool");
    require(address(riskModule) != address(0), "riskModule can't be zero");
    _riskModules.add(address(riskModule));
    _riskModuleStatus[riskModule] = RiskModuleStatus.active;
    emit RiskModuleStatusChanged(riskModule, RiskModuleStatus.active);
  }

  // TODO: removeRiskModule
  // TODO: changeRiskModuleStatus

  function addEToken(IEToken eToken) external onlyRole(ENSURO_DAO_ROLE) {
    require(_eTokens.length() < MAX_ETOKENS, "Maximum number of ETokens reached");
    require(!_eTokens.contains(address(eToken)), "eToken already in the pool");
    require(address(eToken) != address(0), "eToken can't be zero");
    require(eToken.policyPool() == this, "EToken not linked to this pool");

    _eTokens.add(address(eToken));
    _eTokenStatus[eToken] = ETokenStatus.active;
    emit ETokenStatusChanged(eToken, ETokenStatus.active);
  }

  // TODO: removeEToken
  // TODO: changeETokenStatus

  function setAssetManager(address assetManager_) external onlyRole(ENSURO_DAO_ROLE) {
    _assetManager = assetManager_;
    emit AssetManagerChanged(_assetManager);
  }

  function assetManager() external view virtual override returns (address) {
    return _assetManager;
  }

  function deposit(IEToken eToken, uint256 amount) external {
    require(_eTokenStatus[eToken] == ETokenStatus.active, "eToken is not active");
    _currency.safeTransferFrom(_msgSender(), address(this), amount);
    eToken.deposit(_msgSender(), amount);
  }

  function withdraw(IEToken eToken, uint256 amount) external returns (uint256) {
    require(_eTokenStatus[eToken] == ETokenStatus.active ||
            _eTokenStatus[eToken] == ETokenStatus.deprecated,
            "eToken is not active");
    address provider = _msgSender();
    uint256 withdrawed = eToken.withdraw(provider, amount);
    if (withdrawed > 0)
      _transferTo(provider, withdrawed);
    emit Withdrawal(eToken, provider, withdrawed);
    return withdrawed;
  }

  function newPolicy(Policy.PolicyData memory policy_, address customer) external override returns (uint256) {
    IRiskModule rm = policy_.riskModule;
    require(address(rm) == _msgSender(), "Only the RM can create new policies");
    require(_riskModuleStatus[rm] == RiskModuleStatus.active, "RM module is not active");
    _policyCount += 1;
    _currency.safeTransferFrom(customer, address(this), policy_.premium);
    Policy.PolicyData storage policy = _policies[_policyCount] = policy_;
    policy.id = _policyCount;
    _safeMint(customer, policy.id);
    if (policy.rmScr() > 0)
      _currency.safeTransferFrom(rm.wallet(), address(this), policy.rmScr());
    _activePurePremiums +=  policy.purePremium;
    _activePremiums +=  policy.premium;
    _lockScr(policy);
    emit NewPolicy(rm, policy.id);
    return policy.id;
  }

  function _lockScr(Policy.PolicyData storage policy) internal {
    uint256 ocean = 0;
    DataTypes.ETokenToWadMap storage policyFunds = _policiesFunds[policy.id];

    // Initially I iterate over all eTokens and accumulate ocean of eligible ones
    // saves the ocean in policyFunds, later will
    for (uint256 i = 0; i < _eTokens.length(); i++) {
      IEToken etk = IEToken(_eTokens.at(i));
      if (_eTokenStatus[etk] != ETokenStatus.active)
        continue;
      if (!etk.accepts(policy.expiration))
        continue;
      uint256 etkOcean = etk.ocean();
      if (etkOcean == 0)
        continue;
      ocean += etkOcean;
      policyFunds.set(etk, etkOcean);
    }
    _distributeScr(policy.scr, policy.interestRate(), ocean, policyFunds);
  }

  /**
   * @dev Distributes SCR amount in policyFunds according to ocean per token
   * @param scr  SCR to distribute
   * @param ocean  Total ocean available in the ETokens for this SCR
   * @param policyFunds  Input: loaded with ocean available for this SCR (sum=ocean)
                         Ouput: loaded with locked SRC (sum=scr)
   */
  function _distributeScr(uint256 scr, uint256 interestRate, uint256 ocean,
                          DataTypes.ETokenToWadMap storage policyFunds) internal {
    require(ocean >= scr, "Not enought ocean to cover the policy");
    uint256 scr_not_locked = scr;

    for (uint256 i = 0; i < policyFunds.length(); i++) {
      uint256 etkScr;
      (IEToken etk, uint256 etkOcean) = policyFunds.at(i);
      if (i < policyFunds.length() - 1)
        etkScr = scr.wadMul(etkOcean).wadDiv(ocean);
      else
        etkScr = scr_not_locked;
      etk.lockScr(interestRate, etkScr);
      policyFunds.set(etk, etkScr);
      scr_not_locked -= etkScr;
    }
  }

  function _transferTo(address destination, uint256 amount) internal {
    // TODO asset management
    _currency.safeTransfer(destination, amount);
  }

  function _payFromPool(uint256 toPay) internal returns (uint256) {
    // 1. take from won_pure_premiums
    if (toPay <= _wonPurePremiums) {
      _wonPurePremiums -= toPay;
      return 0;
    }
    if (_wonPurePremiums > 0) {
      toPay -= _wonPurePremiums;
      _wonPurePremiums = 0;
    }
    // 2. borrow from active pure premiums
    if (_activePurePremiums > _borrowedActivePP) {
      if (toPay <= (_activePurePremiums - _borrowedActivePP)) {
        _borrowedActivePP += toPay;
        return 0;
      } else {
        toPay -= _activePurePremiums - _borrowedActivePP;
        _borrowedActivePP = _activePurePremiums;
      }
    }
    return toPay;
  }

  function _storePurePremiumWon(uint256 purePremiumWon) internal {
    if (purePremiumWon == 0)
      return;
    if (_borrowedActivePP >= purePremiumWon) {
      _borrowedActivePP -= purePremiumWon;
    } else {
      if (_borrowedActivePP > 0) {
        purePremiumWon -= _borrowedActivePP;
        _borrowedActivePP = 0;
      }
      _wonPurePremiums += purePremiumWon;
    }
  }

  function resolvePolicy(uint256 policyId, bool customerWon) external override {
    Policy.PolicyData storage policy = _policies[policyId];
    require(policy.id == policyId && policyId != 0, "Policy not found");
    IRiskModule rm = policy.riskModule;
    require(address(rm) == _msgSender(), "Only the RM can resolve policies");
    // TODO: validate rm status
    _activePremiums -= policy.premium;
    _activePurePremiums -= policy.purePremium;

    uint256 aux = policy.accruedInterest();
    bool positive = policy.premiumForLps >= aux;
    uint256 adjustment;
    if (positive)
      adjustment = policy.premiumForLps - aux;
    else
      adjustment = aux - policy.premiumForLps;

    uint256 borrowFromScr;
    uint256 purePremiumWon;

    if (customerWon) {
      borrowFromScr = _payFromPool(
        policy.payout - policy.rmScr() - policy.premiumForEnsuro -
        policy.purePremium - policy.premiumForRm
      );
      _transferTo(ownerOf(policy.id), policy.payout);
      purePremiumWon = 0;
    } else {
      // Pay RM and Ensuro
      _transferTo(policy.riskModule.wallet(), policy.premiumForRm + policy.rmScr());
      _transferTo(_treasury, policy.premiumForEnsuro);
      purePremiumWon = policy.purePremium;
      // cover first _borrowedActivePP
      if (_borrowedActivePP > _activePurePremiums) {
        aux = Math.min(_borrowedActivePP - _activePurePremiums, purePremiumWon);
        _borrowedActivePP -= aux;
        purePremiumWon -= aux;
      }
    }

    DataTypes.ETokenToWadMap storage policyFunds = _policiesFunds[policy.id];

    for (uint256 i = 0; i < policyFunds.length(); i++) {
      uint256 scrToken;
      (IEToken etk, uint256 etkScr) = policyFunds.at(i);
      etk.unlockScr(policy.interestRate(), etkScr);
      etk.discreteEarning(adjustment.wadMul(etkScr).wadDiv(policy.scr), positive);
      if (!customerWon && purePremiumWon > 0 && etk.getPoolLoan() > 0) {
        // if debt with token, repay from purePremium
        aux = policy.purePremium.wadMul(etkScr).wadDiv(policy.scr);
        aux = Math.min(purePremiumWon, Math.min(etk.getPoolLoan(), aux));
        etk.repayPoolLoan(aux);
        purePremiumWon -= aux;
      } else {
        if (borrowFromScr > 0) {
          etk.lendToPool(borrowFromScr.wadMul(etkScr).wadDiv(policy.scr));
        }
      }
    }

    _storePurePremiumWon(purePremiumWon);
    // policy.rm.removePolicy...
    emit PolicyResolved(policy.riskModule, policy.id, customerWon);
    delete _policies[policy.id];
    delete _policiesFunds[policy.id];
  }

  function rebalancePolicy(uint256 policyId) external onlyRole(REBALANCE_ROLE) {
    Policy.PolicyData storage policy = _policies[policyId];
    require(policy.id == policyId && policyId != 0, "Policy not found");
    DataTypes.ETokenToWadMap storage policyFunds = _policiesFunds[policyId];
    uint256 ocean = 0;

    // Iterates all the tokens
    // If locked - unlocks - finally stores the available ocean in policyFunds
    for (uint256 i = 0; i < _eTokens.length(); i++) {
      IEToken etk = IEToken(_eTokens.at(i));
      uint256 etkOcean = 0;
      (bool locked, uint256 etkScr) = policyFunds.tryGet(etk);
      if (locked) {
        etk.unlockScr(policy.interestRate(), etkScr);
      }
      if (_eTokenStatus[etk] == ETokenStatus.active && etk.accepts(policy.expiration))
        etkOcean = etk.ocean();
      if (etkOcean == 0) {
        if (locked)
          policyFunds.remove(etk);
      } else {
        policyFunds.set(etk, etkOcean);
        ocean += etkOcean;
      }
    }

    _distributeScr(policy.scr, policy.interestRate(), ocean, policyFunds);
    emit PolicyRebalanced(policy.riskModule, policy.id);
  }

  function getInvestable() external view returns (uint256) {
    uint256 borrowedFromEtk = 0;
    for (uint256 i = 0; i < _eTokens.length(); i++) {
      IEToken etk = IEToken(_eTokens.at(i));
      borrowedFromEtk += etk.getPoolLoan();
    }
    uint256 premiums = _activePremiums + _wonPurePremiums - _borrowedActivePP;
    if (premiums > borrowedFromEtk)
      return premiums - borrowedFromEtk;
    else
      return 0;
  }

  function assetEarnings(uint256 amount, bool positive) external onlyAssetManager {
    if (positive) {
      // earnings
      _storePurePremiumWon(amount);
    } else {
      // losses
      _payFromPool(amount); // return value should be 0 if not, losses are more than capital available
    }
  }

  function getPolicy(uint256 policyId) external override view returns (Policy.PolicyData memory) {
    return _policies[policyId];
  }

  function getPolicyFundCount(uint256 policyId) external view returns (uint256) {
    return _policiesFunds[policyId].length();
  }

  function getPolicyFundAt(uint256 policyId, uint256 index) external view returns (IEToken, uint256) {
     return _policiesFunds[policyId].at(index);
  }

  function getPolicyFund(uint256 policyId, IEToken etoken) external view returns (uint256) {
     (bool success, uint256 amount) = _policiesFunds[policyId].tryGet(etoken);
     if (success)
       return amount;
     else
       return 0;
  }

}
