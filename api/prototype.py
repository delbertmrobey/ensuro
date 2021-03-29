from .wadray import RAY, Ray, Wad
import time

_now = int(time.time())

SECONDS_IN_YEAR = 365 * 24 * 3600


def now():
    global _now
    return _now


class RiskModule:
    def __init__(self, name, mcr_percentage, premium_share, ensuro_share):
        self.name = name
        self.mcr_percentage = mcr_percentage
        self.premium_share = premium_share
        self.ensuro_share = ensuro_share

    @classmethod
    def build(cls, name, mcr_percentage=100, premium_share=0, ensuro_share=0):
        return cls(
            name=name, mcr_percentage=Ray.from_value(mcr_percentage) // Ray.from_value(100),
            premium_share=Ray.from_value(premium_share) // Ray.from_value(100),
            ensuro_share=Ray.from_value(ensuro_share) // Ray.from_value(100)
        )


class Policy:
    def __init__(self, policy_id, risk_module, payout, premium, loss_prob, start, expiration,
                 parameters={}):
        self.policy_id = policy_id
        self.risk_module = risk_module
        self.premium = premium
        self.payout = payout
        self.mcr = ((payout - premium).to_ray() * risk_module.mcr_percentage).to_wad()
        self.loss_prob = loss_prob
        self.start = start
        self.expiration = expiration
        self.parameters = parameters or {}
        self.locked_funds = []

    @property
    def pure_premium(self):
        return (self.payout.to_ray() * self.loss_prob).to_wad()

    @property
    def interest_rate(self):
        profit_premium = self.premium - self.pure_premium
        for_ensuro = (profit_premium.to_ray() * self.risk_module.ensuro_share).to_wad()
        for_risk_module = (profit_premium.to_ray() * self.risk_module.premium_share).to_wad()
        for_lps = profit_premium - for_ensuro - for_risk_module
        return (
            for_lps * Wad.from_value(SECONDS_IN_YEAR) // (
                Wad.from_value(self.expiration - self.start) * self.mcr
            )
        ).to_ray()


class EToken:

    def __init__(self, name, expiration_period, decimals=18):
        self.name = name
        self.expiration_period = expiration_period
        self.current_index = Ray(RAY)
        self.last_index_update = now()
        self.balances = {}
        self.indexes = {}
        self.timestamps = {}
        assert decimals == 18  # Only 18 supported
        self.decimals = decimals
        self.mcr = Wad(0)
        self.mcr_interest_rate = Ray(0)
        self.token_interest_rate = Ray(0)

    @classmethod
    def build(cls, **kwargs):
        return cls(**kwargs)

    def _update_current_index(self):
        self.current_index = self._calculate_current_index()
        self.last_index_update = now()

    def _calculate_current_index(self):
        increment = (
            self.current_index * Ray.from_value(now() - self.last_index_update) *
            self.token_interest_rate // Ray.from_value(SECONDS_IN_YEAR)
        )
        return self.current_index + increment

    def total_supply(self):
        base_supply = sum(self.balances.values(), Wad(0))  # in ERC20 we will use base total_supply
        return (base_supply.to_ray() * self._calculate_current_index()).to_wad()

    @property
    def ocean(self):
        return self.total_supply() - self.mcr

    def lock_mcr(self, policy, mcr_amount):
        total_supply = self.total_supply()
        ocean = total_supply - self.mcr
        assert mcr_amount <= ocean
        self._update_current_index()

        if self.mcr == 0:
            self.mcr = mcr_amount
            self.mcr_interest_rate = policy.interest_rate
        else:
            orig_mcr = self.mcr
            self.mcr += mcr_amount
            self.mcr_interest_rate = (
                self.mcr_interest_rate * orig_mcr.to_ray() + policy.interest_rate * mcr_amount.to_ray()
            ) // self.mcr  # weighted average of previous and policy interest_rate
        self.token_interest_rate = self.mcr_interest_rate * self.mcr.to_ray() // total_supply.to_ray()

    def deposit(self, provider, amount):
        self._update_current_index()
        self.balances[provider] = self.balance_of(provider) + amount
        self.indexes[provider] = self.current_index
        self.timestamps[provider] = now()
        return self.balances[provider]

    def balance_of(self, provider):
        if provider not in self.balances:
            return Wad(0)
        self._update_current_index()
        principal_balance = self.balances[provider]
        return (principal_balance.to_ray() * self.current_index // self.indexes[provider]).to_wad()

    def redeem(self, provider, amount):
        balance = self.balance_of(provider)
        if balance == 0:
            return Wad(0)
        if amount is None or amount > balance:
            amount = balance
        self.balances[provider] = balance - amount
        self._update_current_index()
        if balance == amount:  # full redeem
            del self.balances[provider]
            del self.indexes[provider]
            del self.timestamps[provider]
        else:
            self.indexes[provider] = self.current_index
            self.timestamps[provider] = now()
        return amount

    def accepts(self, policy):
        return policy.expiration <= (now() + self.expiration_period)


class Protocol:
    DECIMALS = 18

    def __init__(self, risk_modules={}, etokens={}):
        self.risk_modules = risk_modules or {}
        self.etokens = etokens or {}
        self.policies = []
        self.policy_count = 0

    @classmethod
    def build(cls, **kwargs):
        return cls(**kwargs)

    def add_risk_module(self, risk_module):
        self.risk_modules[risk_module.name] = risk_module

    def add_etoken(self, etoken):
        self.etokens[etoken.name] = etoken

    def deposit(self, etoken, provider, amount):
        token = self.etokens[etoken]
        return token.deposit(provider, amount)

    def fast_forward_time(self, secs):
        global _now
        _now += secs
        return _now

    def now(self):
        return now()

    def new_policy(self, risk_module_name, payout, premium, loss_prob, expiration, parameters={}):
        rm = self.risk_modules[risk_module_name]
        start = now()
        self.policy_count += 1
        policy = Policy(self.policy_count, rm, payout, premium, loss_prob, start, expiration, parameters)
        assert policy.interest_rate > 0

        ocean = Wad(0)
        ocean_per_token = {}
        for etk in self.etokens.values():
            if not etk.accepts(policy):
                continue
            ocean_token = etk.ocean
            if ocean_token == 0:
                continue
            ocean += ocean_token
            ocean_per_token[etk.name] = ocean_token

        assert ocean >= policy.mcr

        mcr_not_locked = policy.mcr

        for index, (token_name, ocean_token) in enumerate(ocean_per_token.items()):
            if index < (len(ocean_per_token) - 1):
                mcr_for_token = policy.mcr * ocean_token // ocean
            else:  # Last one gets the rest
                mcr_for_token = mcr_not_locked
            self.etokens[token_name].lock_mcr(policy, mcr_for_token)
            policy.locked_funds.append((token_name, mcr_for_token))
            mcr_not_locked -= mcr_for_token

        self.policies.append(policy)
        return policy
