#!/usr/bin/env python3
"""Generate the ranked "<tool> alternatives" pages in docs/blog/.

One data source (TOOLS) feeds every page, so a price change updates all of
them. Each entry in PAGES only sets the order, the topic copy and the FAQs.
Competitor facts must match the docs/compare pages; if a claim can't be
traced to one of them, leave it out.

    python3 scripts/build-alternatives.py
"""
import html
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BLOG = REPO / "docs" / "blog"
BASE = "https://meetmouse.com"

CHECKED = "July 29, 2026"
MODIFIED = "2026-10-01"

TOOLS = {
    "meetmouse": {
        "name": "MeetMouse",
        "best": "Private live coaching on a Mac",
        "price": "$20 once. No subscription, no account. 30-day refund.",
        "cell": "$20 once",
        "free": "No free plan",
        "bot": "No",
        "audio": "Stays on your Mac",
        "review": (
            "I built MeetMouse because years of transcripts never made me better at meetings. "
            "It listens on your Mac, shows a live transcript and talk balance, and nudges you "
            "during the call: land the ask, let them finish, pin down that vague \"sounds good.\" "
            "Transcription and AI run on your Mac by default and it works with WiFi off. "
            "Pick it if privacy matters or you want to change the meeting, not file it away."
        ),
        "good": [
            "No bot, no account, works with WiFi off",
            "Coaching cues during the call, hidden from screen shares",
            "$20 once, cheaper than two months of most paid plans",
        ],
        "bad": [
            "Mac only (macOS 14.2 or later)",
            "No CRM sync or team dashboard",
            "If you turn on Claude or OpenAI in Settings, text goes to that provider (audio never does)",
        ],
    },
    "fathom": {
        "name": "Fathom",
        "site": "https://fathom.video",
        "vs": "/compare/meetmouse-vs-fathom",
        "best": "Free notes with no minute cap",
        "price": "Free for individuals. Teams from $19/user/month.",
        "cell": "Free",
        "free": "Unlimited recordings and summaries",
        "bot": "Yes",
        "audio": "Their cloud",
        "review": (
            "The best free notetaker, and I said so on my own comparison page. Recordings, "
            "transcripts and AI summaries with no minute cap. The trade is a visible bot in "
            "your calls and every meeting in their cloud. If neither bothers you, get Fathom."
        ),
        "good": [
            "Free individual plan with no minute cap",
            "Recordings, transcripts and AI summaries",
            "Team features from $19/user/month when you need them",
        ],
        "bad": [
            "A Fathom bot joins your calls",
            "Your meetings live in their cloud",
        ],
    },
    "granola": {
        "name": "Granola",
        "site": "https://www.granola.ai",
        "vs": "/compare/meetmouse-vs-granola",
        "best": "Notes with no bot in the call",
        "price": "Free with a 25-note history cap. Business $14/user/month.",
        "cell": "Free, then $14/user/mo",
        "free": "Unlimited meetings, history capped at 25 notes",
        "bot": "No",
        "audio": "Cloud AI for notes",
        "review": (
            "The tool I respect most on this list. Granola captures system audio on your Mac, "
            "so nobody named Granola joins the call and the notes are excellent. Notes are "
            "written with cloud AI, so it isn't the privacy pick. Pick it if the bot is your problem."
        ),
        "good": [
            "No bot: it captures system audio on your Mac",
            "Excellent notes",
            "Free plan is enough for a light meeting load",
        ],
        "bad": [
            "Notes are generated with cloud AI",
            "Free history caps at 25 notes on a rolling window",
        ],
    },
    "otter": {
        "name": "Otter",
        "site": "https://otter.ai",
        "vs": "/compare/meetmouse-vs-otter",
        "best": "Searching months of old transcripts",
        "price": "Free for 300 minutes a month. Pro $16.99/month.",
        "cell": "Free 300 min, then $16.99/mo",
        "free": "300 minutes a month",
        "bot": "Yes",
        "audio": "Their cloud",
        "review": (
            "Otter has been transcribing meetings the longest, and search across months of "
            "transcripts is excellent. It's the default for researchers and journalists. "
            "The free plan is about a week of real meetings. Pick it if the archive is the point."
        ),
        "good": [
            "Strong search across months of meetings",
            "The default for researchers and journalists",
        ],
        "bad": [
            "Free plan stops at 300 minutes a month",
            "Announces itself with a bot in every call",
            "Audio is processed in their cloud",
        ],
    },
    "fireflies": {
        "name": "Fireflies",
        "site": "https://fireflies.ai",
        "vs": "/compare/meetmouse-vs-fireflies",
        "best": "Sales teams that need CRM sync",
        "price": "Free plan with limited AI credits. Pro from $18/user/month.",
        "cell": "From $18/user/mo",
        "free": "Unlimited recording, limited AI credits",
        "bot": "Yes",
        "audio": "Their cloud and your CRM",
        "review": (
            "Fireflies is infrastructure for sales orgs: record every call, score it, push it "
            "to the CRM and let managers review talk time across the team. For one person "
            "it's a truck when you need a bicycle. Pick it if you run a sales team."
        ),
        "good": [
            "Pushes calls into your CRM",
            "Call scoring and manager dashboards",
            "Free plan records unlimited meetings",
        ],
        "bad": [
            "Overkill for one person",
            "A bot joins every call",
            "Priced per seat",
        ],
    },
    "tldv": {
        "name": "tl;dv",
        "site": "https://tldv.io",
        "best": "Sharing clips with your team",
        "price": "Free unlimited recordings. Pro $29/month flat, not per seat.",
        "cell": "Free, then $29/mo",
        "free": "Unlimited recordings, deleted after 3 months",
        "bot": "Yes",
        "audio": "Their cloud",
        "review": (
            "If what you share with your team is \"watch these 40 seconds,\" tl;dv's clipping "
            "beats everyone's. Pro is one flat price for a small team. Free recordings delete "
            "after 3 months, so the free plan has a shot clock."
        ),
        "good": [
            "Best clip-sharing on the list",
            "Pro is $29/month flat, not per seat",
        ],
        "bad": [
            "Free recordings delete after 3 months",
            "A bot joins calls and recordings live in their cloud",
        ],
    },
}

NOT_RANKED = {
    "poised": (
        "Poised",
        "It coaches live too, but it coaches delivery (filler words, pace, confidence) as a "
        "cloud subscription with an account. A good pick if public-speaking mechanics are the "
        "problem.",
        "/compare/meetmouse-vs-poised",
    ),
    "memo": (
        "Voice memo + an AI chat",
        "$0. Record with QuickTime or Voice Memos, drop the file into ChatGPT or Claude and ask "
        "for a summary with action items. No bot, no subscription, just a few manual steps. "
        "I did this for months.",
        None,
    ),
}

PAGES = [
    {
        "slug": "fathom-alternatives",
        "incumbent": "Fathom",
        "topic": "Fathom alternatives",
        "title": "The 5 Best Fathom Alternatives in 2026 (Ranked, With Prices)",
        "description": "The 5 best Fathom alternatives, ranked by a founder who competes with them: MeetMouse, Granola, Otter, tl;dv and Fireflies, with real prices and who each one is for.",
        "h1": "The 5 best Fathom alternatives in 2026",
        "order": ["meetmouse", "granola", "otter", "tldv", "fireflies"],
        "quick": (
            "<strong>MeetMouse</strong> is the best Fathom alternative if you want no bot and "
            "nothing in anyone's cloud: $20 once, on your Mac. Fathom is free, so nobody leaves "
            "it over price. Pick <strong>Granola</strong> if the bot is your only problem, "
            "<strong>Otter</strong> if you want deeper archive search, and <strong>Fireflies</strong> "
            "if you're really a sales team."
        ),
        "intro": (
            "Fathom is the best free notetaker on the market, and I'm not walking that back. "
            "People leave it for three reasons: a bot named Fathom joins every call, every "
            "recording lives on their servers, or six months of beautiful summaries never made "
            "anyone better at meetings. Yes, I make MeetMouse, so it's first. Every other tool "
            "below says what it does better than us."
        ),
        "enough": (
            "If the bot doesn't change how your guests talk and you're fine with the cloud, stay "
            "on Fathom. Its free plan is the most generous on this page, and plenty of people run "
            "MeetMouse alongside it: Fathom for the record, MeetMouse for the rep."
        ),
        "not_ranked": ["poised", "memo"],
        "faqs": [
            ("Is any Fathom alternative as good for free?",
             "For pure free notetaking, no. Granola's free plan caps history at 25 notes, Otter's stops at 300 minutes a month, and tl;dv deletes free recordings after 3 months. People switch over the bot, the cloud, or wanting more than notes."),
            ("What's the best Fathom alternative without a bot?",
             "Granola, which captures system audio on your Mac so no participant joins the call. MeetMouse is also bot-free and keeps transcription and AI on your Mac by default."),
            ("Is there a Fathom alternative that doesn't store meetings in the cloud?",
             "MeetMouse. Transcription and AI run on your Mac by default and it works with WiFi off. Every notetaker on this list, including bot-free Granola, uses cloud AI."),
            ("Can a meeting tool make you better at meetings instead of just taking notes?",
             "That's MeetMouse's whole premise: live cues during the call, like talk balance, buried asks and vague commitments, instead of a summary after it."),
        ],
    },
    {
        "slug": "otter-alternatives",
        "incumbent": "Otter",
        "topic": "Otter alternatives",
        "title": "The 5 Best Otter.ai Alternatives in 2026 (Ranked, With Prices)",
        "description": "The 5 best Otter.ai alternatives, ranked by a founder who competes with them: MeetMouse, Fathom, Granola, Fireflies and tl;dv, with real prices and who each one is for.",
        "h1": "The 5 best Otter.ai alternatives in 2026",
        "order": ["meetmouse", "fathom", "granola", "fireflies", "tldv"],
        "quick": (
            "<strong>MeetMouse</strong> is the best Otter alternative if you want no bot and no "
            "cloud: $20 once, against Otter Pro at $16.99 a month. If the 300-minute free plan is "
            "your only problem, pick <strong>Fathom</strong>: free with no minute cap. Pick "
            "<strong>Granola</strong> if the bot is the problem and <strong>Fireflies</strong> if "
            "you run a sales team."
        ),
        "intro": (
            "People leave Otter for one of three reasons: 300 free minutes a month disappear in a "
            "week of real meetings, the \"Otter.ai has joined\" announcement makes every call a "
            "little more awkward, or every word of every meeting is sitting in someone else's "
            "cloud. Yes, I make MeetMouse, so it's first. Every other tool below says what it does "
            "better than us."
        ),
        "enough": (
            "If you search old transcripts every week, Otter's archive is the thing you'd miss. "
            "Stay on Pro. MeetMouse deliberately doesn't build a searchable cloud archive."
        ),
        "not_ranked": ["poised", "memo"],
        "faqs": [
            ("What is the best free alternative to Otter.ai?",
             "Fathom. Its free individual plan has no minute cap, while Otter's free tier stops at 300 minutes a month. The trade-off is the same as Otter's: a visible bot joins your calls and recordings live in Fathom's cloud."),
            ("Is there an Otter alternative without a bot joining the meeting?",
             "Yes. Granola takes notes by capturing system audio on your Mac, so no bot appears in the call. MeetMouse is also bot-free and keeps transcription and AI on your Mac by default."),
            ("Is there an Otter alternative that works offline?",
             "MeetMouse works with WiFi off because transcription and coaching run on your Mac. Every other option on this list, including Otter, processes audio in the cloud."),
            ("Does any Otter alternative avoid a subscription?",
             "MeetMouse is $20 one time, with no subscription and no account. Everything else on this list is a free tier plus a monthly plan."),
        ],
    },
    {
        "slug": "fireflies-alternatives",
        "incumbent": "Fireflies",
        "topic": "Fireflies alternatives",
        "title": "The 5 Best Fireflies.ai Alternatives in 2026 (Ranked, With Prices)",
        "description": "The 5 best Fireflies.ai alternatives, ranked by a founder who competes with them: MeetMouse, Fathom, Otter, Granola and tl;dv, with real prices and who each one is for.",
        "h1": "The 5 best Fireflies.ai alternatives in 2026",
        "order": ["meetmouse", "fathom", "otter", "granola", "tldv"],
        "quick": (
            "<strong>MeetMouse</strong> is the best Fireflies alternative for one person who "
            "wants a private coach instead of a recorded dashboard: $20 once, against Fireflies "
            "Pro from $18 per user per month. Pick <strong>Fathom</strong> if you need the "
            "individual basics free, <strong>Granola</strong> for notes with no bot, and "
            "<strong>tl;dv</strong> for a small team on a budget."
        ),
        "intro": (
            "Fireflies is built for sales orgs: record every call, score it, push it to the CRM. "
            "People look for alternatives from two directions. You're one person and $18 per user "
            "per month for enterprise machinery is absurd, or you're on a team and every "
            "conversation being recorded and reviewable started to itch. Yes, I make MeetMouse, "
            "so it's first. Every other tool below says what it does better than us."
        ),
        "enough": (
            "If you manage a sales team that needs every call in the CRM and scored for managers, "
            "Fireflies is built for exactly that. Stay. MeetMouse is for one person, and nobody "
            "else sees its coaching."
        ),
        "not_ranked": ["poised", "memo"],
        "faqs": [
            ("What is the best free alternative to Fireflies?",
             "For individuals, Fathom: free with no minute cap, covering recording, transcription and summaries. Fireflies' own free plan exists but limits AI credits."),
            ("Is there a Fireflies alternative that doesn't send a bot into meetings?",
             "Granola takes notes with no bot by capturing system audio on your Mac. MeetMouse is also bot-free and keeps transcription and AI on your Mac by default."),
            ("Do any Fireflies alternatives coach you during the call?",
             "MeetMouse does, with live cues like talk balance, buried asks and vague commitments in an overlay only you see. Fireflies and the other notetakers analyze calls after they end."),
            ("What's the cheapest Fireflies alternative for a small team?",
             "tl;dv. Pro is $29 a month flat rather than per seat, versus Fireflies from $18 per user per month. For one person, Fathom's free plan beats both."),
        ],
    },
    {
        "slug": "free-granola-alternatives",
        "incumbent": "Granola",
        "topic": "Free Granola alternatives",
        "title": "Free Granola Alternatives: The 5 Best Options in 2026 (Ranked)",
        "description": "The best free Granola alternatives once the 25-note cap hits, ranked by a founder who competes with them: Fathom, tl;dv, Otter, Fireflies, plus MeetMouse at $20 once.",
        "h1": "Free Granola alternatives: the 5 best options in 2026",
        "order": ["meetmouse", "fathom", "tldv", "otter", "fireflies"],
        "badge": "Best value",
        "quick": (
            "If it has to be free, use <strong>Fathom</strong>: unlimited recordings and summaries "
            "with no monthly cap, but a bot joins your calls. If you'll pay once instead of every "
            "month, <strong>MeetMouse</strong> is $20 once, against Granola Business at $14 per user "
            "per month, and it coaches you live without a bot. Under 25 meetings worth keeping? "
            "Granola's own free plan is enough."
        ),
        "intro": (
            "Granola is genuinely good, and its free plan is genuinely free, until your note "
            "history hits 25 meetings on a rolling window. Take meetings for a living and you hit "
            "that in two weeks. Then it's $14 per user per month, forever. MeetMouse isn't free, "
            "so I'm saying it up front: it's first because $20 once is the cheapest way off a "
            "subscription. Every other tool below says what it does better than us."
        ),
        "enough": (
            "If you have fewer than about 25 meetings worth remembering at any time, Granola's "
            "free plan might already be everything you need. It's bot-free, the notes are "
            "excellent, and the history cap is the whole business model. Under it? Stop shopping."
        ),
        "not_ranked": ["memo", "poised"],
        "faqs": [
            ("What is the best free alternative to Granola?",
             "Fathom. Its free plan has unlimited recordings and summaries with no monthly cap. The catch is that a bot joins your calls and meetings are stored in Fathom's cloud."),
            ("Is there a free Granola alternative without a bot?",
             "Granola's own free plan is the bot-free free option, until the 25-note history cap. Recording with Voice Memos and pasting into an AI chat is also bot-free and costs nothing."),
            ("Is there a Granola alternative without a subscription?",
             "MeetMouse is $20 one time, with no subscription and no account. It coaches you live instead of writing notes afterward."),
            ("Why does Granola's free plan stop working?",
             "Granola's free plan keeps your last 25 notes on a rolling window. Past that, only your latest 25 stay in your history unless you pay $14 per user per month for Business."),
        ],
    },
]

CSS = """
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; background: #fff; color: #1a1a1a; line-height: 1.6; -webkit-font-smoothing: antialiased; }
  main { max-width: 680px; margin: 0 auto; padding: 48px 24px 96px; }
  .crumb { font-size: 14px; margin-bottom: 28px; color: #888; }
  .crumb a { color: #888; text-decoration: none; }
  .crumb a:hover { color: #1a1a1a; }
  h1 { font-size: 36px; line-height: 1.15; letter-spacing: -0.02em; font-weight: 700; }
  .byline { display: flex; align-items: center; justify-content: space-between; gap: 12px 16px; flex-wrap: wrap; margin: 20px 0 26px; padding-bottom: 20px; border-bottom: 1px solid #eee; }
  .byline .who { display: flex; align-items: center; gap: 12px; }
  .byline img { width: 44px; height: 44px; border-radius: 50%; display: block; }
  .byline .name { font-weight: 700; font-size: 15px; line-height: 1.3; }
  .byline .role, .byline .date { font-size: 14px; color: #888; }
  .quick { background: linear-gradient(135deg, #f6f7f9, #eceef2); border: 1px solid #e5e5e5; border-radius: 14px; padding: 18px 22px; font-size: 16px; color: #333; }
  .pill { display: inline-block; font-size: 12px; font-weight: 700; letter-spacing: .02em; color: #1a1a1a; background: #fff; border: 1px solid #e0e0e0; border-radius: 999px; padding: 2px 10px; margin-bottom: 8px; }
  .quick p { font-size: 16px; }
  .buy { margin: 22px 0 6px; }
  .buy-btn { display: inline-block; background: #111; color: #fff; font-size: 16px; font-weight: 600; border: none; border-radius: 10px; padding: 13px 26px; cursor: pointer; text-decoration: none; font-family: inherit; }
  .buy-btn:hover { background: #333; }
  .cta-note { font-size: 14px; color: #888; margin-top: 10px; }
  article { margin-top: 28px; }
  article h2 { font-size: 24px; letter-spacing: -0.01em; margin: 48px 0 14px; }
  article h3 { font-size: 17px; margin: 26px 0 8px; }
  article p { color: #333; font-size: 16px; margin-bottom: 16px; }
  article ol { padding-left: 22px; color: #333; font-size: 16px; margin-bottom: 16px; }
  article li { margin-bottom: 8px; }
  article a { color: #1a1a1a; }
  .table-wrap { overflow-x: auto; margin: 24px 0; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #eee; vertical-align: top; }
  th { font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; color: #999; white-space: nowrap; }
  tr.us td { background: #f6f7f9; font-weight: 600; }
  table.rank td:first-child { color: #999; width: 28px; }
  table.rank a { text-decoration: none; font-weight: 600; }
  .badge { display: inline-block; font-size: 11px; font-weight: 700; color: #fff; background: #111; border-radius: 999px; padding: 2px 8px; margin-left: 6px; vertical-align: middle; white-space: nowrap; }
  .tool { border-top: 1px solid #eee; padding-top: 30px; margin-top: 34px; }
  .tool.us { background: #f6f7f9; border: 1px solid #e5e5e5; border-radius: 16px; padding: 26px 24px; }
  .tool h3 { font-size: 22px; margin: 0; }
  .tool .num { font-size: 14px; font-weight: 700; color: #999; margin-right: 6px; }
  .best { font-weight: 600; margin: 6px 0 10px; color: #1a1a1a; }
  .facts { font-size: 15px; color: #333; margin-bottom: 12px; }
  .facts span { color: #888; display: inline-block; min-width: 52px; }
  .shot { margin: 18px 0 22px; }
  .shot img { width: 100%; height: auto; display: block; border: 1px solid #e5e5e5; border-radius: 12px; }
  .shot figcaption { font-size: 13px; color: #888; margin-top: 8px; text-align: center; }
  .procon { display: grid; grid-template-columns: 1fr 1fr; gap: 6px 24px; margin: 14px 0; }
  .procon p { font-weight: 700; font-size: 14px; margin: 0 0 4px; color: #1a1a1a; }
  .procon ul { list-style: none; padding: 0; margin: 0; }
  .procon li { font-size: 15px; line-height: 1.5; padding: 3px 0 3px 22px; position: relative; color: #333; margin: 0; }
  .good li::before { content: "\\2713"; position: absolute; left: 0; color: #1f9d55; font-weight: 700; }
  .bad li::before { content: "\\2715"; position: absolute; left: 1px; color: #999; font-size: 13px; top: 5px; }
  .links { display: flex; gap: 20px; flex-wrap: wrap; align-items: center; font-size: 15px; margin-top: 4px; }
  .tm { font-size: 13px; color: #999; margin-top: 28px; }
  footer { margin-top: 72px; padding-top: 24px; border-top: 1px solid #eee; font-size: 13px; color: #999; }
  footer a { color: #999; }
  @media (max-width: 560px) { h1 { font-size: 29px; } .procon { grid-template-columns: 1fr; } .tool.us { padding: 20px 16px; } }
"""

PAYPAL = """<form action="https://www.paypal.com/cgi-bin/webscr" method="post">
      <input type="hidden" name="cmd" value="_xclick">
      <input type="hidden" name="business" value="paypal@okdork.com">
      <input type="hidden" name="item_name" value="MeetMouse for Mac">
      <input type="hidden" name="amount" value="20.00">
      <input type="hidden" name="currency_code" value="USD">
      <input type="hidden" name="no_shipping" value="1">
      <input type="hidden" name="return" value="https://meetmouse.com/thanks.html">
      <input type="hidden" name="cancel_return" value="https://meetmouse.com/">
      <button type="submit" class="buy-btn">Buy MeetMouse, $20 once</button>
    </form>"""

e = html.escape


def card(key, n, badge):
    t = TOOLS[key]
    us = key == "meetmouse"
    head = f'<h3><span class="num">{n:02d}</span>{e(t["name"])}'
    if us:
        head += f'<span class="badge">{badge}</span>'
    head += "</h3>"
    good = "".join(f"<li>{e(x)}</li>" for x in t["good"])
    bad = "".join(f"<li>{e(x)}</li>" for x in t["bad"])
    shot = ""
    if us:
        shot = ('<figure class="shot"><img src="/img/meetmouse-live-coaching.jpg" width="1200" height="522" '
                'loading="lazy" alt="MeetMouse during a call: live transcript, talk balance and coaching cues">'
                '<figcaption>MeetMouse during a call: live transcript, talk balance and coaching cues.</figcaption></figure>')
        links = f'{PAYPAL}<a href="/">How MeetMouse works</a>'
    else:
        links = f'<a href="{t["site"]}" rel="nofollow noopener" target="_blank">{e(t["name"])} website &#8599;</a>'
        if t.get("vs"):
            links += f'<a href="{t["vs"]}">MeetMouse vs {e(t["name"])}</a>'
    return f"""
    <section class="tool{' us' if us else ''}" id="{key}">
      {head}
      <p class="best">Best for: {e(t["best"][0].lower() + t["best"][1:])}</p>
      <p class="facts"><span>Price</span> {e(t["price"])}</p>
      {shot}
      <p>{e(t["review"])}</p>
      <div class="procon">
        <div class="good"><p>Good</p><ul>{good}</ul></div>
        <div class="bad"><p>Not so good</p><ul>{bad}</ul></div>
      </div>
      <div class="links">{links}</div>
    </section>"""


def page(p):
    badge = p.get("badge", "Best overall")
    order = p["order"]
    url = f'{BASE}/blog/{p["slug"]}'
    rows = ""
    for i, k in enumerate(order, 1):
        t = TOOLS[k]
        b = f'<span class="badge">{badge}</span>' if k == "meetmouse" else ""
        cls = ' class="us"' if k == "meetmouse" else ""
        rows += (f'<tr{cls}><td>{i}</td>'
                 f'<td><a href="#{k}">{e(t["name"])}</a>{b}</td><td>{e(t["best"])}</td><td>{e(t["cell"])}</td></tr>')
    grid_keys = order + ([] if p["incumbent"].lower() in order else [p["incumbent"].lower()])
    grid = ""
    for k in grid_keys:
        t = TOOLS[k]
        cls = ' class="us"' if k == "meetmouse" else ""
        grid += (f'<tr{cls}><td>{e(t["name"])}</td><td>{e(t["free"])}</td>'
                 f'<td>{e(t["price"])}</td><td>{t["bot"]}</td><td>{e(t["audio"])}</td></tr>')
    cards = "".join(card(k, i, badge) for i, k in enumerate(order, 1))
    nr = ""
    for k in p["not_ranked"]:
        name, why, link = NOT_RANKED[k]
        more = f' <a href="{link}">MeetMouse vs {e(name)}</a>' if link else ""
        nr += f"<p><strong>{e(name)}.</strong> {e(why)}{more}</p>"
    if p.get("count_extra"):
        nr += (f"<p><strong>{e(p['count_extra'])}.</strong> Not an alternative, but often the right "
               "answer. See the section above.</p>")
    faqs = "".join(f"<h3>{e(q)}</h3><p>{e(a)}</p>" for q, a in p["faqs"])
    names = [TOOLS[k]["name"] for k in order]
    graph = {
        "@context": "https://schema.org",
        "@graph": [
            {"@type": "Article", "headline": p["h1"], "datePublished": "2026-07-29", "dateModified": MODIFIED,
             "image": f"{BASE}/img/meetmouse-live-coaching.jpg",
             "author": {"@type": "Person", "name": "Noah Kagan", "jobTitle": "Founder",
                        "worksFor": {"@type": "Organization", "name": "MeetMouse", "url": BASE}},
             "publisher": {"@type": "Organization", "name": "MeetMouse", "url": BASE}},
            {"@type": "ItemList", "name": p["topic"],
             "itemListElement": [{"@type": "ListItem", "position": i, "name": n} for i, n in enumerate(names, 1)]},
            {"@type": "BreadcrumbList", "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "MeetMouse", "item": f"{BASE}/"},
                {"@type": "ListItem", "position": 2, "name": "Blog", "item": f"{BASE}/blog/"},
                {"@type": "ListItem", "position": 3, "name": p["topic"], "item": url}]},
            {"@type": "FAQPage", "mainEntity": [
                {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in p["faqs"]]},
        ],
    }
    related = " · ".join(
        f'<a href="/blog/{q["slug"]}">{e(q["topic"])}</a>' for q in PAGES if q["slug"] != p["slug"])
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(p["title"])}</title>
<meta name="description" content="{e(p["description"])}">
<link rel="canonical" href="{url}">
<link rel="icon" type="image/png" href="/icon.png">
<meta property="og:type" content="article">
<meta property="og:url" content="{url}">
<meta property="og:title" content="{e(p["title"])}">
<meta property="og:description" content="{e(p["description"])}">
<meta property="og:image" content="https://meetmouse.com/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="MeetMouse: coached live, on your Mac. $20 once.">
<meta property="article:modified_time" content="{MODIFIED}">
<meta name="twitter:card" content="summary_large_image">
<script type="application/ld+json">
{json.dumps(graph, indent=1)}
</script>
<style>{CSS}</style>
</head>
<body>
<main>
  <p class="crumb"><a href="/">MeetMouse</a> / <a href="/blog/">Blog</a> / {e(p["topic"])}</p>

  <h1>{e(p["h1"])}</h1>
  <div class="byline">
    <div class="who">
      <img src="/img/noah.jpg" alt="Noah Kagan" width="44" height="44">
      <div><div class="name">Noah Kagan</div><div class="role">Founder, MeetMouse</div></div>
    </div>
    <div class="date">Prices checked {CHECKED}</div>
  </div>

  <div class="quick"><span class="pill">Quick answer</span><p>{p["quick"]}</p></div>

  <div class="buy">
    {PAYPAL}
    <p class="cta-note">One-time purchase for macOS 14.2+. No subscription, no account. 30-day money-back guarantee.</p>
  </div>

  <article>
    <p>{e(p["intro"])}</p>

    <div class="table-wrap">
      <table class="rank">
        <tr><th>#</th><th>Tool</th><th>Best for</th><th>Price for one person</th></tr>
        {rows}
      </table>
    </div>
{cards}

    <h2>What each costs</h2>
    <div class="table-wrap">
      <table>
        <tr><th>Tool</th><th>Free plan</th><th>Paid</th><th>Bot joins?</th><th>Where audio goes</th></tr>
        {grid}
      </table>
    </div>
    <p class="cta-note">Prices for one person, monthly billing, read from each tool's pricing page on {CHECKED}. Check before you buy; these change.</p>

    <h2>When {e(p["incumbent"])} is enough</h2>
    <p>{e(p["enough"])}</p>

    <h2>Checked, but not ranked</h2>
    {nr}

    <h2>How we checked</h2>
    <p>Every price and plan limit comes from the tool's own pricing page or help docs, read on {CHECKED}, for one person paying monthly. The ranking is for one person on Zoom, Meet or Teams who cares where their meetings go and wants to get better at them, not a sales team. Nobody paid to be on this list. I make MeetMouse, and its price is the one on this site.</p>

    <h2>How to switch</h2>
    <ol>
      <li>Buy MeetMouse for $20 and open the DMG.</li>
      <li>Allow the microphone and Screen Recording, so it hears both sides without a bot.</li>
      <li>Start your next Zoom, Meet or Teams call. Want to try it first? The 15-second demo needs no permissions.</li>
      <li>Keep {e(p["incumbent"])} running alongside if you still want its archive. They don't know about each other.</li>
    </ol>

    <h2>Questions people ask</h2>
    {faqs}

    <p>More from this site: {related} · <a href="/compare/meetmouse-vs-granola">vs Granola</a> · <a href="/compare/meetmouse-vs-otter">vs Otter</a> · <a href="/compare/meetmouse-vs-fathom">vs Fathom</a> · <a href="/compare/meetmouse-vs-fireflies">vs Fireflies</a> · <a href="/compare/meetmouse-vs-poised">vs Poised</a></p>
    <p class="tm">All trademarks belong to their owners. Named for comparison only.</p>
  </article>

  <div class="buy">
    {PAYPAL}
    <p class="cta-note">One-time purchase. No subscription, no account. 30-day money-back guarantee.</p>
  </div>

  <footer>
    <p>MeetMouse · <a href="mailto:support@meetmouse.com">support@meetmouse.com</a> · <a href="/">Home</a> · <a href="/blog/">Blog</a> · <a href="/changelog">Changelog</a></p>
  </footer>
</main>
</body>
</html>
"""


def main():
    for p in PAGES:
        out = page(p)
        assert "—" not in out, f"em dash in {p['slug']}"
        (BLOG / f'{p["slug"]}.html').write_text(out)
        print(f'wrote docs/blog/{p["slug"]}.html')


if __name__ == "__main__":
    main()
