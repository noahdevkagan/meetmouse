"""The ranked "<tool> alternatives" blog posts, rendered by site/build.py.

One data source (TOOLS) feeds every page, so a price change updates all of
them. Each entry in PAGES only sets the order, the topic copy and the FAQs.
Competitor facts must match the compare pages and best.py; if a claim can't be
traced to one of them, leave it out. Format: the ranked-comparison house style
(quick answer, ranked table, one card per tool, trust sections).
"""

CHECKED = "October 2, 2026"
MODIFIED = "2026-10-02"

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
            "The best free notetaker on the market. Recordings, "
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
        "price": "Free with 30 days of meeting history. Business $14/user/month.",
        "cell": "Free, then $14/user/mo",
        "free": "Unlimited meetings, 30 days of history",
        "bot": "No",
        "audio": "Cloud AI for notes",
        "review": (
            "Granola captures system audio on your Mac, "
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
            "Free plan keeps only 30 days of meeting history",
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
        "vs": "/compare/meetmouse-vs-tldv",
        "best": "Sharing clips with your team",
        "price": "Free with unlimited recordings and AI notes on 10 meetings. Pro $29/seat/month.",
        "cell": "Free, then $29/seat/mo",
        "free": "Unlimited recordings, AI notes on 10 meetings, data kept up to 3 months",
        "bot": "Yes",
        "audio": "Their cloud",
        "review": (
            "If what you share with your team is \"watch these 40 seconds,\" tl;dv's clipping "
            "beats everyone's. The free plan records without limits, but AI notes stop after "
            "10 meetings and data is kept up to 3 months. Pro is $29 per seat per month."
        ),
        "good": [
            "Best clip-sharing on the list",
            "Free plan records unlimited meetings",
        ],
        "bad": [
            "Free AI notes stop after 10 meetings; data kept up to 3 months",
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
        "for a summary with action items. No bot, no subscription, just a few manual steps.",
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
            "Fathom is the best free notetaker on the market. "
            "People leave it for three reasons: a bot named Fathom joins every call, every "
            "recording lives on their servers, or six months of beautiful summaries never made "
            "anyone better at meetings. I make MeetMouse, so it's listed first. Each tool "
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
             "For pure free notetaking, no. Granola's free plan keeps 30 days of history, Otter's stops at 300 minutes a month, and tl;dv's free AI notes stop after 10 meetings. People switch over the bot, the cloud, or wanting more than notes."),
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
            "cloud. I make MeetMouse, so it's listed first. Each tool below says what it does "
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
            "<strong>Otter</strong> if transcript search is what you'd miss."
        ),
        "intro": (
            "Fireflies is built for sales orgs: record every call, score it, push it to the CRM. "
            "People look for alternatives from two directions. You're one person and $18 per user "
            "per month for enterprise machinery is absurd, or you're on a team and every "
            "conversation being recorded and reviewable started to itch. I make MeetMouse, "
            "so it's listed first. Each tool below says what it does better than us."
        ),
        "enough": (
            "If you manage a sales team that needs every call in the CRM and scored for managers, "
            "Fireflies is built for exactly that. Stay. MeetMouse is for one person, and nobody "
            "else sees its coaching."
        ),
        "not_ranked": ["poised", "memo"],
        "faqs": [
            ("What is the best free alternative to Fireflies?",
             "For individuals, Fathom: free with no minute cap, covering recording, transcription and summaries. Fireflies' own free plan exists but limits AI summaries."),
            ("Is there a Fireflies alternative that doesn't send a bot into meetings?",
             "Granola takes notes with no bot by capturing system audio on your Mac. MeetMouse is also bot-free and keeps transcription and AI on your Mac by default."),
            ("Do any Fireflies alternatives coach you during the call?",
             "MeetMouse does, with live cues like talk balance, buried asks and vague commitments in an overlay only you see. Fireflies and the other notetakers analyze calls after they end."),
            ("Is there a cheaper Fireflies alternative for a team?",
             "Not by much. Billed monthly, Fireflies Pro is $18 per seat, Otter Pro is $16.99, Fathom Team is $19 and tl;dv Pro is $29. For one person, Fathom's free plan beats all of them."),
        ],
    },
    {
        "slug": "free-granola-alternatives",
        "incumbent": "Granola",
        "topic": "Free Granola alternatives",
        "title": "Free Granola Alternatives: The 5 Best Options in 2026 (Ranked)",
        "description": "The best free Granola alternatives once the 30-day history limit hits, ranked: Fathom, tl;dv, Otter, Fireflies, plus MeetMouse as a $20 one-time paid upgrade.",
        "h1": "Free Granola alternatives: the 5 best options in 2026",
        "order": ["fathom", "meetmouse", "tldv", "otter", "fireflies"],
        "badge": "Best paid upgrade",
        "us_best": "A paid upgrade: $20 once, no subscription",
        "quick": (
            "If it has to be free, use <strong>Fathom</strong>: unlimited recordings and summaries "
            "with no monthly cap, but a bot joins your calls. If you'll pay once instead of every "
            "month, <strong>MeetMouse</strong> is $20 once, against Granola Business at $14 per user "
            "per month, and it coaches you live without a bot. Only need the last 30 days? "
            "Granola's own free plan is enough."
        ),
        "intro": (
            "Granola is genuinely good, and its free plan is genuinely free, but it only keeps 30 "
            "days of meeting history. Keeping more costs $14 per user per month. I make MeetMouse, "
            "so it's on this list even though it isn't free: it's $20 once. Each tool below says "
            "what it does better than us."
        ),
        "enough": (
            "If you only need your last 30 days of meetings, Granola's free plan might already be "
            "everything you need. It's bot-free and the notes are excellent. The history limit is "
            "the whole business model. Inside it? Stop shopping."
        ),
        "not_ranked": ["memo", "poised"],
        "faqs": [
            ("What is the best free alternative to Granola?",
             "Fathom. Its free plan has unlimited recordings and summaries with no monthly cap. The catch is that a bot joins your calls and meetings are stored in Fathom's cloud."),
            ("Is there a free Granola alternative without a bot?",
             "Granola's own free plan is the bot-free free option, with 30 days of meeting history. Recording with Voice Memos and pasting into an AI chat is also bot-free and costs nothing."),
            ("Is there a Granola alternative without a subscription?",
             "MeetMouse is $20 one time, with no subscription and no account. It coaches you live instead of writing notes afterward."),
            ("What are the limits of Granola's free plan?",
             "Granola's free Basic plan keeps 30 days of meeting history. Unlimited history needs Business at $14 per user per month."),
        ],
    },
]

