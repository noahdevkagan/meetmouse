"""Central pricing source for MeetMouse and all competitors.

All monetary values used across Python content (best.py, alternatives.py, compare.py),
build scripts (build.py), templates, and articles are managed here.
"""

class PricingDict(dict):
    """Dictionary supporting dot-notation attribute access."""
    def __getattr__(self, name):
        try:
            val = self[name]
            if isinstance(val, dict) and not isinstance(val, PricingDict):
                val = PricingDict(val)
                self[name] = val
            return val
        except KeyError:
            raise AttributeError(f"No pricing attribute {name!r}")

    def __setattr__(self, name, value):
        self[name] = value


UNLOCK_CODE = "MOUSE-5KC5-7EDA"

PRICES = PricingDict({
    "meetmouse": {
        "price": "$20",
        "unlock_code": UNLOCK_CODE,
    },
    "granola": {
        "business": "$14",
        "enterprise": "$35",
        "annual_yr": "$168",
        "history_days": "30",
        "business_10": "$140",
        "business_25": "$350",
        "enterprise_25": "$875",
    },
    "fathom": {
        "free": "$0",
        "premium": "$20",
        "premium_annual": "$16",
        "team": "$19",
        "team_annual": "$15",
        "business": "$34",
        "business_annual": "$25",
        "team_5_reps": "$95",
        "team_10_reps": "$190",
        "team_25_reps": "$475",
        "team_annual_5": "$75",
        "team_annual_10": "$150",
        "team_annual_25": "$375",
        "biz_5_reps": "$170",
        "biz_10_reps": "$340",
        "biz_25_reps": "$850",
        "biz_annual_5": "$125",
        "biz_annual_10": "$250",
        "biz_annual_25": "$625",
    },
    "otter": {
        "free": "$0",
        "pro": "$16.99",
        "pro_annual": "$8.33",
        "pro_annual_yr": "$204",
        "business": "$30",
        "business_annual": "$19.99",
        "pro_5_reps": "$85",
        "pro_annual_5": "$42",
        "pro_10_reps": "$170",
        "pro_annual_10": "$83",
        "pro_25_reps": "$425",
        "pro_annual_25": "$208",
        "biz_5_reps": "$150",
        "biz_annual_5": "$100",
        "biz_10_reps": "$300",
        "biz_annual_10": "$200",
        "biz_25_reps": "$750",
        "biz_annual_25": "$500",
    },
    "fireflies": {
        "free": "$0",
        "pro": "$18",
        "pro_annual": "$10",
        "pro_annual_yr": "$120",
        "pro_monthly_yr": "$216",
        "business": "$29",
        "business_annual": "$19",
        "enterprise": "$59",
    },
    "tldv": {
        "free": "$0",
        "pro": "$29",
        "pro_annual": "$18",
        "business": "$39",
    },
    "poised": {
        "pro": "$19",
        "pro_annual": "$13",
        "pro_annual_yr": "$156",
    },
    "yoodli": {
        "free": "$0",
        "pro": "$8",
        "advanced": "$20",
    },
    "krisp": {
        "pro": "$16",
        "pro_annual_yr": "$96",
    },
    "shadow": {
        "pro": "$19",
    },
    "descript": {
        "creator": "$15",
        "pro": "$30",
    },
    "limitless": {
        "pro": "$20",
        "pro_annual_yr": "$228",
    },
})


def get_page_pricing_context():
    """Return a flat dictionary of standard price placeholder variables."""
    return {
        "price": PRICES.meetmouse.price,
        "otter_price": PRICES.otter.pro,
        "otter_annual": PRICES.otter.pro_annual_yr,
        "otter_annual_mo": PRICES.otter.pro_annual,
        "otter_biz": PRICES.otter.business,
        "granola_price": PRICES.granola.business,
        "fireflies_price": PRICES.fireflies.pro,
        "fireflies_biz": PRICES.fireflies.business,
        "fireflies_annual_mo": PRICES.fireflies.pro_annual,
        "fathom_price": PRICES.fathom.team,
        "premium_price": PRICES.fathom.premium,
        "annual_price": PRICES.fathom.premium_annual,
        "team_price": PRICES.fathom.team,
        "business_price": PRICES.fathom.business,
        "fathom_team_total": PRICES.fathom.team_25_reps,
        "fathom_biz_total": PRICES.fathom.biz_25_reps,
        "annual_cost": PRICES.otter.pro_annual_yr,
        "pro_price": PRICES.fireflies.pro,
        "biz_price": PRICES.fireflies.business,
        "tldv_price": PRICES.tldv.pro,
        "annual": PRICES.tldv.pro_annual,
    }
