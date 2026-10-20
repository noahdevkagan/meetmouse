"""The /best/* guides, one dict per page. Rendered by site/build.py.

Rules (see decisions.md 2026-09-30): Noah's voice, bias disclosed in the dek,
MeetMouse marked `mine` and not forced to #1 where something else fits better,
no invented anecdotes, competitor prices only where already verified on this
site (otherwise described without a number), and a `checked` month.
"""

MM_WHERE = "On your Mac. Local AI by default; if you add your own Claude or OpenAI key, meeting text goes to that provider."
MM_PRICE = "Free for 3 meetings a week; $20 once for unlimited"
REFUND = "Unlimited your first week, then 3 meetings a week. Invite 2 friends or pay $20 once for unlimited."

GRANOLA = dict(name="Granola", price="Free (30 days of history); Business $14/user/mo",
               where="Captured on your computer (no bot); notes made with cloud AI", local="No", url="https://www.granola.ai/")
FATHOM = dict(name="Fathom", price="Free; Premium $20/mo; Team $19/user/mo (2-seat min)",
              where="A bot records the call by default (bot-free capture in beta); stored in Fathom's cloud", local="No", url="https://www.fathom.ai/")
OTTER = dict(name="Otter", price="Free 300 min/mo; Pro $16.99/mo",
             where="A bot records the call; stored in Otter's cloud", local="No", url="https://otter.ai/")
FIREFLIES = dict(name="Fireflies", price="From $18/user/mo",
                 where="A bot records the call; stored in Fireflies' cloud", local="No", url="https://fireflies.ai/")
TLDV = dict(name="tl;dv", price="Free (data kept up to 3 months); Pro $29/seat/mo ($18 annual)",
            where="A bot records the call; stored in tl;dv's cloud", local="No", url="https://tldv.io/")
MACWHISPER = dict(name="MacWhisper", price="Free tier; one-time Pro license",
                  where="On your Mac", local="Yes", url="https://goodsnooze.gumroad.com/l/macwhisper")
GONG = dict(name="Gong", price="Custom enterprise pricing",
            where="Calls recorded and stored in Gong's cloud", local="No", url="https://www.gong.io/")
POISED = dict(name="Poised", price="Free tier; paid subscription",
              where="Captured on your computer; processed in Poised's cloud", local="No", url="https://www.poised.com/")


def mm(best_for, body):
    return dict(name="MeetMouse", mine=True, best_for=best_for, price=MM_PRICE, where=MM_WHERE,
                local="Yes, by default", body=body, url="/")


def pick(base, best_for, body, **kw):
    return {**base, "best_for": best_for, "body": body, **kw}


BEST = [
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/ai-notetaker-for-mac",
        label="Best AI notetaker for Mac",
        blurb="Native Mac apps vs meeting bots — who hears FaceTime, who works offline, and who's worth paying for.",
        title="Best AI Notetaker for Mac (2026): 6 Picks From a Mac Developer",
        description="The best AI notetakers for Mac — Granola, MeetMouse, Fathom, Otter, MacWhisper — compared on bots, offline use, Apple Silicon and price. Honest picks from someone who makes one.",
        headline="The best AI notetaker for Mac (2026)",
        dek="Full disclosure: I make MeetMouse, and it only runs on a Mac. So I'm biased. I'm still going to tell you when something else is the better pick, including the free stuff.",
        short_answer="On a Mac, pick between a native app that hears your Mac's audio (no bot joins, works in any app, including FaceTime) and a bot service that joins the call (works anywhere, but everyone sees it). Then ask the question nobody asks until it matters: does the AI run on your Mac or on their servers?",
        short_picks=[
            ("Best bot-free notes for a team", "Granola"),
            ("Best free", "Fathom"),
            ("Best for recordings, offline", "MacWhisper"),
            ("Nothing leaves your Mac, plus live coaching", "MeetMouse, free to start (mine)"),
        ],
        intro=[("Two kinds of Mac notetaker", [
            "Native apps listen to your Mac's audio directly. No bot joins, and they hear anything: Zoom, Meet, Teams, FaceTime, a Slack huddle, a browser tab. They need the Screen Recording permission, because that's how macOS gates system audio. It doesn't mean they're recording your screen.",
            "Bot services send a participant into the call. They work the same on any computer, but everyone sees them, the host can block them, and they can't hear FaceTime.",
        ])],
        picks=[
            pick(GRANOLA, "bot-free notes you share with a team", [
                "Granola made \"no bot\" a category. You type rough notes, it fills them in after the call, and they're genuinely good. Shared folders make it work for teams, and it has Windows and iPhone apps.",
                "The catch: notes are made with cloud AI, you need an account, and the free plan keeps only 30 days of history.",
            ]),
            pick(FATHOM, "free, if you're fine with a bot", [
                "Best free plan in the category, period. A bot named Fathom joins your call by default and everything lives on their servers. It works the same on a Mac as anywhere else, which also means it can't hear FaceTime.",
            ]),
            pick(OTTER, "a searchable archive of every meeting", [
                "Otter's been doing this forever and the cross-meeting search is legit. But 300 free minutes a month is one busy Tuesday, and it's a bot plus the cloud.",
            ]),
            pick(MACWHISPER, "turning recordings into text, offline", [
                "Point it at a recording and you get an accurate transcript without touching the internet. It's a transcription tool, not a meeting assistant: no live help, light on summaries. For interviews and lectures, great value.",
            ]),
            mm("nothing leaving your Mac, plus coaching during the call", [
                "Mine. Every tool above tells you what happened after the meeting. MeetMouse coaches you while it's happening: a short cue in a small overlay when you're monologuing, skipped the ask, or rolled past a concern. The overlay doesn't show up in screen shares.",
                "It writes notes too — topics, next steps, who owns what — and you can ask any saved meeting a question. Transcription and AI run on your Mac. Turn Wi-Fi off mid-call and it keeps going. No bot, no account, no telemetry.",
                "Limits: Mac only, macOS 14.2 or newer. Apple Silicon recommended; on Intel it falls back to Apple's built-in transcription, which is less accurate. No team workspace.",
            ]),
        ],
        verdict=[
            "If you want a written record your team can see and the cloud doesn't bother you, Granola. If you want free, Fathom.",
            "If you'd rather your meetings never leave the laptop, or the real problem is how the meetings go, not remembering them, that's why I built MeetMouse.",
        ],
        today=[
            "Decide your one dealbreaker: the bot, the cloud, or the monthly bill. That alone picks your shortlist.",
            "If free matters most, install Fathom and use it on three meetings this week.",
            "If privacy matters most, try the Wi-Fi test: start a meeting in any tool, turn Wi-Fi off, and see if it keeps working.",
            "If you want to get better in meetings, try MeetMouse on your next five calls. It's free for 3 meetings a week, so finding out costs nothing.",
        ],
        faq=[
            ("What's the best AI notetaker for Mac?", "Granola for bot-free team notes. Fathom if you want free and don't mind a bot. MeetMouse if you want everything to stay on your Mac plus live coaching during the call, free for 3 meetings a week ($20 once for unlimited)."),
            ("Which Mac notetakers work offline?", "MeetMouse (transcription and AI run on your Mac, so it works with Wi-Fi off) and MacWhisper (for recordings). Granola, Fathom and Otter need the internet."),
            ("Why do Mac notetakers ask for Screen Recording permission?", "That's how macOS gates system audio — the other side of the call. Bot-free apps like Granola and MeetMouse need it to hear the meeting. It doesn't mean they record your screen."),
            ("Does MeetMouse work on Intel Macs?", "Yes, on macOS 14.2 or later, but Apple Silicon is recommended. On Intel, the high-accuracy transcription and speaker identification aren't available, so it uses Apple's built-in transcription."),
        ],
        cta_body="Free to start. No subscription, no account, no bot in your call, and your meetings stay on your Mac. " + REFUND,
        checked="September 2026",
    ),
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/ai-meeting-assistant-for-sales-calls",
        label="Best AI meeting assistant for sales calls",
        blurb="Gong, Fireflies, Fathom, Granola — and the one that catches the buried objection while you can still answer it.",
        title="Best AI Meeting Assistant for Sales Calls (2026): Honest Picks",
        description="The best AI tools for sales calls — Gong, Fireflies, Fathom, Granola, MeetMouse — compared on live coaching, CRM sync, bots and price.",
        headline="The best AI meeting assistant for sales calls (2026)",
        dek="Full disclosure: I make MeetMouse. It's built to help during the call, on your Mac, and it's the only one here with no CRM sync. So which one wins depends on whether you're buying for the org or for the rep on the call.",
        short_answer="Almost every sales AI works after the call: record, summarize, push to the CRM, and let a manager review it next week. That's great for the org. Almost none of it works during the call, when the rep can still address the objection or ask for the next step.",
        short_picks=[
            ("Best for a sales org with RevOps", "Gong"),
            ("Best CRM notes on a small budget", "Fireflies or Fathom"),
            ("Best when buyers hate the bot", "Granola"),
            ("Best live coaching for the rep", "MeetMouse, free to start (mine)"),
        ],
        intro=[("After the call vs during it", [
            "A recap tells you that you talked 70% of the call and never asked for next steps. By then the buyer has hung up. Live cues are the only format that changes this deal. The setup that works for a lot of teams: the org keeps its recorder for the CRM, and reps run a private live coach next to it.",
        ])],
        picks=[
            pick(GONG, "sales orgs with RevOps and a budget", [
                "The category leader: recordings, deal risk, forecasting, and a call library managers mine for coaching. Priced for enterprises and sold through a sales process. The coaching happens in review sessions, after the call.",
            ]),
            pick(FIREFLIES, "CRM plumbing for smaller teams", [
                "Records, transcribes, scores and pushes to the CRM for a fraction of Gong. A bot joins every call.",
            ]),
            pick(FATHOM, "free call notes that fill in CRM fields", [
                "If you're a rep who just wants great call notes for free, get Fathom. The bot is visible; some buyers don't care, some go quiet.",
            ]),
            pick(GRANOLA, "buyer calls where a bot kills the vibe", [
                "Enterprise and procurement calls get weird when a recorder joins. Granola hears the call through your computer instead. Cloud notes, light CRM story.",
            ]),
            mm("the rep, during the call", [
                "Mine. It listens through your Mac — the buyer sees nothing — and watches the conversation live. When they raise a concern and you steamroll past it, you get a cue like \"CFO cost worry just came up. Pause the roadmap and circle back to it.\" It also flags when you've talked too long and when \"sounds good\" wasn't a next step. The overlay is hidden from screen shares, so you can demo with it running.",
                "After the call: notes with next steps and owners. The coaching rubric is editable, so you can add your own discovery questions. No CRM sync; it's for you, not your manager.",
            ]),
        ],
        verdict=[
            "Buying for a sales org: Gong if you can afford it, Fireflies or Fathom if you can't.",
            "Buying for yourself, to win the call you're on: MeetMouse. Run it next to whatever your team records with.",
        ],
        today=[
            "Pull your last three lost deals and find the moment each one turned. Was it a skipped objection, no next step, or you talking too long?",
            "If it was any of those, that's a live problem. A recap tool won't fix it.",
            "Keep your team's recorder for the CRM. Nothing here requires ripping anything out.",
            "Try MeetMouse on your next ten calls. It's free for 3 meetings a week, so finding out costs nothing.",
        ],
        faq=[
            ("What's the best AI tool for sales calls?", "For sales orgs, Gong (enterprise) or Fireflies (smaller budgets). For free notes, Fathom. For live coaching during the call — catching buried objections and missed asks — MeetMouse, free to start."),
            ("Is there real-time AI coaching for sales calls?", "Yes. MeetMouse shows short cues during the call in an overlay only you see. Gong, Fireflies and Fathom mostly help after the call from a recording."),
            ("Will the buyer know I'm using AI?", "With Gong, Fireflies and Fathom, a recorder joins the call. MeetMouse and Granola capture audio on your computer, so nothing joins. Recording-consent laws still apply either way."),
            ("Does MeetMouse sync to Salesforce or HubSpot?", "No. It keeps meetings on your Mac. Plenty of reps run it next to the team's recorder: the recorder feeds the CRM, MeetMouse coaches them live."),
        ],
        cta_body="Free to start. No bot on the buyer's screen, nothing uploaded. " + REFUND,
        checked="September 2026",
    ),
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/ai-notetaker-for-lawyers",
        label="Best AI notetaker for lawyers",
        blurb="Before any AI hears a client call, ask one question: who else hears it?",
        title="Best AI Notetaker for Lawyers (2026): Start With Where the Call Goes",
        description="Which AI notetakers make sense for client calls? Cloud tools vs on-device options compared on confidentiality, bots, retention and cost. Not legal advice — just how the tools move data.",
        headline="The best AI notetaker for lawyers (2026)",
        dek="Full disclosure: I make MeetMouse, and I'm not a lawyer. This isn't legal or ethics advice; your bar and your firm get the final say. What I can tell you is how these tools actually move data, because that's the part the marketing pages get fuzzy about.",
        short_answer="For lawyers, the deciding question isn't which summary is prettiest. It's who else hears the conversation. A cloud notetaker sends it to the vendor, and usually to an AI company behind them. A bot notetaker also shows up in the meeting and may email a recap to everyone on the invite. A tool that runs on your own computer skips the vendor question entirely.",
        short_picks=[
            ("Best for privileged calls", "MeetMouse, on your Mac, free to start (mine)"),
            ("Best for recorded interviews", "MacWhisper"),
            ("Best if your firm has vetted a cloud vendor", "Granola or Otter on a business plan"),
        ],
        intro=[("Five questions to ask any vendor", [
            "Does audio or transcript text ever leave my device, and to whom? Which AI companies see it, and do they keep it? What's the default retention, and can I actually delete it? Does it auto-email recaps to attendees? Does it announce itself in the meeting?",
        ])],
        picks=[
            mm("privileged calls where nothing can leave the laptop", [
                "Mine. It hears the call through your Mac, so no bot joins. Transcription runs on-device and the default AI runs locally; pull the Wi-Fi mid-call and it keeps working. You get notes with next steps, and you can ask a saved meeting what was said about a term and jump to the timestamp. No MeetMouse account, no MeetMouse server holding your client's information.",
                "Two things to know. You can add your own Claude or OpenAI key for a bigger model; then meeting text goes to that provider, so leave it on local for client work. And it's a personal Mac tool: no matter management, no firm-wide archive.",
            ]),
            pick(MACWHISPER, "turning recorded interviews into text", [
                "If you already record (with consent) and just need text, MacWhisper transcribes on your Mac. Nothing uploaded.",
            ]),
            pick(GRANOLA, "firms that have reviewed and approved it", [
                "A good product with no bot. It processes conversations in the cloud, so it belongs on a firm-approved business plan, not a personal free account.",
            ]),
            pick(OTTER, "firms that want a searchable archive and approved it", [
                "Strong search across matters. Bot plus cloud, so the same rule applies: through the firm, not a personal account.",
            ]),
            pick(FATHOM, "your non-privileged calls", [
                "I recommend Fathom all the time. Not for privileged calls: visible bot, cloud storage, recap emails.",
            ]),
        ],
        verdict=[
            "Solo or small firm on a Mac: use something that runs locally and move on. That's what MeetMouse is for.",
            "Bigger firm: ask IT what's already approved before you buy anything. Local tools are the easiest to get approved, because there's no vendor to review.",
            "If you also dictate memos and letters, my other app, <a href=\"https://rhinovoice.app/best/dictation-app-for-lawyers\">Rhino Voice</a>, does that on-device too.",
        ],
        today=[
            "Ask your IT or ethics contact one question: \"Can I use a cloud notetaker on client matters?\" The answer decides the rest.",
            "Check whether any tool you already use emails recaps to attendees automatically, and turn that off.",
            "Keep consent practices the same no matter which tool you pick.",
            "If you want AI notes with no third party, try MeetMouse on a week of internal calls first.",
        ],
        faq=[
            ("Is it safe for lawyers to use AI notetakers?", "It depends on where the conversation goes. Cloud notetakers send it to the vendor and often to AI sub-processors. On-device tools like MeetMouse keep it on your Mac by default. Check your jurisdiction's ethics guidance and your firm's policies."),
            ("Which AI notetaker doesn't send client calls to the cloud?", "MeetMouse runs transcription and its default AI on your Mac and works with Wi-Fi off. MacWhisper transcribes recordings locally. Granola, Otter, Fathom and Fireflies process in their cloud."),
            ("Do I still need consent?", "Yes. Recording and transcription consent rules vary by jurisdiction. On-device processing changes who receives the data, not your consent obligations."),
            ("Can I use MeetMouse for depositions?", "Use a court reporter for the official record. MeetMouse is for your own live calls and notes."),
            ("What's the best AI notetaker for a law firm handling privileged client conversations?", "Start with where the conversation goes, not the summary quality. For privileged calls, pick a tool that keeps audio and transcript on your own computer: MeetMouse does that on a Mac, with no bot and no vendor account. If your firm wants a central archive across matters, that's a cloud tool on a business plan your firm has reviewed, and the review comes before the first client call."),
            ("What's the best AI notetaker for a practice that bills by the hour?", "One that saves you the write-up after every call, because that's the time you can't bill cleanly. MeetMouse gives you a summary, decisions and next steps the moment the call ends, and you can ask a saved meeting what was said about a term. It doesn't track time or push entries into billing software, so you still log the hours yourself."),
            ("Does a bot join my client calls?", "With Otter, Fireflies and Fathom's default setup, yes: a visible participant joins and recaps can be emailed to attendees. Granola and MeetMouse capture audio on your computer, so nothing joins the call."),
        ],
        cta_body="Free to start. No account, no vendor holding your client calls, and it works with Wi-Fi off. " + REFUND,
        checked="October 2026",
    ),
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/ai-meeting-tool-for-founders",
        label="Best AI meeting tool for founders",
        blurb="Pitches, customer discovery, hiring — the calls where one sentence matters more than the summary.",
        title="Best AI Meeting Tool for Founders (2026): Pitches, Discovery, Hiring",
        description="The best AI meeting tools for startup founders — investor pitches, customer discovery and hiring calls. Honest picks from a founder who makes one.",
        headline="The best AI meeting tool for founders (2026)",
        dek="Full disclosure: I make MeetMouse. I've also started a few companies (AppSumo, SumoMe, now MeetMouse), so I know the calls founders care about come down to a couple of sentences, not the summary.",
        short_answer="Founder calls are high stakes, few people, sensitive (your runway, their pain), and decided by a handful of moments. Use a notetaker for memory and a coach for performance. The pitch you replay in your head for a week is the one where you needed a nudge at minute four, not a summary at minute forty-five.",
        short_picks=[
            ("Best for pitches and discovery", "MeetMouse, free to start (mine)"),
            ("Best record of investor calls, no bot", "Granola"),
            ("Best free notes for the early team", "Fathom"),
            ("Best for sharing customer clips", "tl;dv"),
        ],
        intro=[],
        picks=[
            mm("pitches, discovery calls and negotiations", [
                "Mine. Discovery call: it notices you've talked for three straight minutes or answered your own question. Investor pitch: when they ask about churn twice, you get a cue to deal with it before the meeting ends. Hiring: it nudges you when the candidate got cut off. All in an overlay only you see, hidden from screen shares, so you can present your deck with it running.",
                "No bot, so nothing named \"Notetaker\" joins in front of a VC. Your fundraising conversations stay on your Mac. Notes with next steps after.",
            ]),
            pick(GRANOLA, "a written record of every investor call", [
                "Clean notes on every investor and customer call, no bot. Cloud notes; the free plan keeps 30 days of history.",
            ]),
            pick(FATHOM, "free notes once a few people take calls", [
                "Hard to beat free. Some investors and enterprise buyers mind the bot. Most don't.",
            ]),
            pick(TLDV, "getting the team to hear the customer", [
                "Clip the 40 seconds where a customer describes the pain and drop it in Slack. Worth more than any summary.",
            ]),
        ],
        verdict=[
            "For the calls that decide the company — pitches, discovery, negotiations — MeetMouse. For a record of everything, add Granola or Fathom. They don't conflict.",
        ],
        today=[
            "Before your next discovery call, write the three questions you must ask. Then shut up and let them talk.",
            "After your next pitch, write down the one question you fumbled. That's your prep for the next one.",
            "Turn on Fathom's free plan if you have nothing recording customer calls yet.",
            "Try MeetMouse on your next pitch or discovery call. It's free for 3 meetings a week, so finding out costs nothing.",
        ],
        faq=[
            ("What's the best AI meeting tool for founders?", "MeetMouse for live coaching on pitches and discovery calls (free to start, on your Mac). Granola for bot-free notes, Fathom for free team notes."),
            ("Should I use an AI notetaker on investor calls?", "Lots of founders do, but a visible bot can change the room. Bot-free tools like MeetMouse and Granola capture audio on your computer, so nothing joins. Mention it if you're recording."),
            ("Can AI help with customer discovery?", "The biggest discovery mistake is talking too much. MeetMouse tracks talk balance live and nudges you when you're pitching instead of listening."),
            ("Does MeetMouse keep fundraising conversations private?", "By default, yes. Transcription and AI run on your Mac and nothing is uploaded."),
        ],
        cta_body="Free to start. No bot in front of investors, nothing uploaded. " + REFUND,
        checked="October 2026",
    ),
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/ai-notetaker-for-recruiters",
        label="Best AI notetaker for recruiters",
        blurb="Candidate calls where a bot spooks people — and interviewer habits that cost you good hires.",
        title="Best AI Notetaker for Recruiters & Hiring Managers (2026)",
        description="The best AI notetakers for recruiters and hiring managers — bot vs no bot, candidate privacy, integrations and live interview coaching.",
        headline="The best AI notetaker for recruiters and hiring managers (2026)",
        dek="Full disclosure: I make MeetMouse. Recruiting has two different problems, and my app only solves one of them, so I'll tell you which.",
        short_answer="Recruiters need throughput: notes without typing, ideally into their systems. Hiring managers need better interviews: more candidate talk, better follow-ups. Both are talking to nervous candidates who notice when a bot named \"Notetaker\" joins.",
        short_picks=[
            ("Best for high-volume recruiting teams", "Fireflies or Fathom"),
            ("Best bot-free notes", "Granola"),
            ("Best for running better interviews", "MeetMouse, free to start (mine)"),
        ],
        intro=[("A note on candidate data", [
            "Interview notes are personal data about people who never agreed to your vendor's terms. Fewer copies in fewer clouds is the safe default. And tell candidates you take AI notes.",
        ])],
        picks=[
            pick(FIREFLIES, "throughput for recruiting teams", [
                "Transcribes screens and pushes notes into your tools. Bot joins, data lives in their cloud; make sure your candidate privacy notice covers it.",
            ]),
            pick(FATHOM, "free interview summaries", [
                "Great free summaries. The visible bot can make early-stage candidates stiffen up.",
            ]),
            pick(GRANOLA, "notes with no bot on candidate calls", [
                "Polished notes, nothing joins the call. Cloud AI.",
            ]),
            mm("hiring managers who want to interview better", [
                "Mine. It watches the live conversation and nudges you when you've been talking too long, when the candidate got cut off, or when a concern came up that you didn't dig into. No bot, so candidates see nothing. The coaching rubric is editable, so you can add the interview habits you care about.",
                "After: notes with topics and next steps, and you can ask what the candidate said about a topic and jump to the timestamp. No ATS integration; it's for the interviewer, not the pipeline.",
            ]),
        ],
        verdict=[
            "Recruiters running volume: Fireflies or Fathom. Hiring managers who want sharper interviews: MeetMouse. Plenty of teams should have both.",
        ],
        today=[
            "Pick one role and write the three things every interviewer must learn. Share it before the next loop.",
            "Add a line to your interview invite saying you take AI notes.",
            "For your next interview, aim to talk less than a third of the time.",
            "Try MeetMouse for a week of interviews. It's free for 3 meetings a week, so finding out costs nothing.",
        ],
        faq=[
            ("What's the best AI notetaker for interviews?", "Fireflies or Fathom for recruiting teams that need integrations. Granola for bot-free notes. MeetMouse for hiring managers who want live coaching during the interview."),
            ("Do candidates see the AI notetaker?", "Bot tools (Fireflies, Otter, and Fathom by default) join as a visible participant. MeetMouse and Granola capture audio on your computer, so nothing joins. Tell candidates either way."),
            ("Can I customize the coaching for interviews?", "Yes. MeetMouse's coaching rubric is editable, so you can add the interviewing habits you want to be nudged on."),
            ("Is candidate data stored in the cloud?", "With cloud notetakers, yes. MeetMouse keeps transcripts and notes on your Mac by default, with no account."),
        ],
        cta_body="Free to start. No bot for candidates to see, and interview notes stay on your Mac. " + REFUND,
        checked="September 2026",
    ),
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/ai-note-taker-for-interviews",
        label="Best AI note taker for interviews",
        blurb="Hiring interviews and research calls: get the notes without a bot making people stiffen up.",
        title="Best AI Note Taker for Interviews (2026): Hiring + Research",
        description="The best AI note taker for job interviews and user research calls. Bot vs no bot, free plan limits, where the recording goes, and which tool fits which interviewer.",
        headline="The best AI note taker for interviews (2026)",
        dek="Full disclosure: I make MeetMouse. Interviews are where I think a notetaker matters most, because the person across from you is already nervous, and that's exactly when a bot named \"Notetaker\" joining the call does damage.",
        short_answer="The best AI note taker for interviews is the one the other person never notices. For hiring interviews and user research calls, pick a tool that captures audio on your own computer instead of sending a bot: MeetMouse (on your Mac, free for 3 meetings a week, and it coaches you to talk less while it happens) or Granola (cloud notes, no bot). If you're a recruiting team that needs notes in your systems at volume, Fireflies or Fathom. If you already record research sessions with consent, MacWhisper turns the files into text on your Mac.",
        short_picks=[
            ("Best for interviewers who want to interview better", "MeetMouse, free to start (mine)"),
            ("Best bot-free cloud notes", "Granola"),
            ("Best for high-volume recruiting teams", "Fireflies or Fathom"),
            ("Best for recorded research sessions", "MacWhisper"),
        ],
        intro=[
            ("Why interviews are different from every other meeting", [
                "In a team meeting, a bot is a small annoyance. In an interview, it changes the answers. Candidates get more careful. Research participants start giving you the polite version instead of the real one. The whole point of the call is to hear what people actually think, so the less your tooling announces itself, the better your notes get.",
                "The second difference is that you're not supposed to be the one talking. A good interview is maybe 70% them. Almost every interviewer talks more than they think, and no recap the next morning fixes that.",
            ]),
            ("Hiring interviews vs research interviews", [
                "Hiring interviews need fair, comparable notes across candidates, and they involve personal data about people who never agreed to your vendor's terms. Research interviews need quotes you can trust and a way to find the moment someone said the thing, weeks later, when you're writing up findings.",
                "Both need consent. Tell people you take AI notes, whatever you use. On-device tools change who receives the conversation, not whether you should ask.",
            ]),
            ("Watch the free plan limits", [
                "Free plans and interviews don't always mix. Otter's free plan stops each conversation at 30 minutes and keeps your 25 most recent, so a 45-minute interview gets cut off. Fathom's free plan records unlimited calls with instant summaries; its more advanced summaries and action items are on Premium. Granola's free plan shows 30 days of meeting history, which runs out in the middle of a hiring loop. MeetMouse is unlimited your first week, then 3 meetings a week, with notes never locked.",
            ]),
        ],
        picks=[
            mm("interviewers who want better interviews, not just notes", [
                "Mine. It hears the call through your Mac, so nothing joins and the candidate or participant sees nothing. While you talk it shows your talk balance and nudges you when you've been going too long, when you cut someone off, or when they raised something you didn't dig into. Those nudges sit in an overlay that stays out of your screen share.",
                "After the call: topic-by-topic notes and next steps, and you can open any saved interview and ask what someone said about pricing or their last manager, with the answer pointing to the timestamp. Transcription and the default AI run on your Mac. What it doesn't do: push notes into an ATS or a research repository. It's for the interviewer, not the pipeline.",
            ]),
            pick(GRANOLA, "bot-free notes when cloud AI is fine", [
                "Captures audio on your computer, so no bot joins, and the notes are excellent. Notes are written with cloud AI, and the free plan's 30 days of history is short for a hiring loop. Business is $14 per user per month.",
            ]),
            pick(FIREFLIES, "recruiting teams that need notes in their tools", [
                "Built for teams: transcribe every screen and push the notes into the systems your team already uses. A bot joins each call and the data lives in their cloud, so make sure your candidate privacy notice covers it.",
            ]),
            pick(FATHOM, "free interview summaries", [
                "The most generous free plan here: unlimited recordings and instant summaries. A bot joins by default, which can make early-stage candidates stiffen up; Fathom has a bot-free option in beta.",
            ]),
            pick(MACWHISPER, "turning recorded research sessions into text", [
                "If you already record sessions with consent and just need transcripts for synthesis, MacWhisper transcribes the files on your Mac. Nothing uploaded, no live notes or coaching.",
            ]),
            pick(OTTER, "a searchable archive of many interviews", [
                "Search across months of transcripts is Otter's strength, which helps when you're digging through 30 research calls. The free plan's 30-minute cap per conversation is the catch for interviews; Pro raises it to 90 minutes. A bot joins the call.",
            ]),
        ],
        verdict=[
            "If you run the interviews yourself and want to get better at them, use MeetMouse. The bot never shows up, and the nudge to stop talking is worth more than any summary.",
            "If you're a recruiting team processing volume, use Fireflies or Fathom and accept the bot. Plenty of teams run both: the team tool for the record, MeetMouse for the interviewer.",
            "For deeper reading on the hiring side, see my <a href=\"/best/ai-notetaker-for-recruiters\">best AI notetaker for recruiters</a> guide.",
        ],
        today=[
            "Add one line to your interview invite: \"I take AI notes so I can listen instead of type.\" Nobody minds that.",
            "Write down the three questions you want answered by the end of the call. Check them off before you hang up.",
            "Aim for them talking 70% of the time on your next interview. Then check how you actually did.",
            "Try MeetMouse on your next three interviews. It's free for 3 meetings a week, so finding out costs nothing.",
        ],
        faq=[
            ("What is the best AI note taker for interviews?", "For interviewers who want no bot and better interviews, MeetMouse, which runs on your Mac and coaches you live. For bot-free cloud notes, Granola. For recruiting teams that need integrations, Fireflies or Fathom. For recorded research sessions, MacWhisper."),
            ("Is there an AI interview note taker that doesn't join the meeting?", "Yes. MeetMouse and Granola capture audio on your computer, so no bot joins. Fathom has bot-free capture in beta. Otter and Fireflies join as a visible participant."),
            ("Is it legal to use an AI note taker in a job interview?", "Recording and transcription consent rules vary by place, and this isn't legal advice. The common practice is to tell the candidate up front. On-device tools change who receives the conversation, not your consent obligations."),
            ("Can AI help with user research interviews?", "Yes: live notes during the call, and afterwards a way to find exact quotes. MeetMouse lets you ask a saved interview what someone said and jumps to the timestamp. MacWhisper is good for transcribing recorded sessions on your Mac."),
            ("Which free AI note taker works for long interviews?", "Fathom records unlimited calls free. MeetMouse is unlimited your first week, then 3 meetings a week. Otter's free plan stops each conversation at 30 minutes."),
        ],
        cta_body="Free to start. No bot for the person across from you to notice, and interview notes stay on your Mac. " + REFUND,
        checked="October 2026",
    ),
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/ai-notetaker-for-consultants",
        label="Best AI notetaker for consultants",
        blurb="Client-run meetings that block bots, NDAs that make the cloud awkward, and billable hours.",
        title="Best AI Notetaker for Consultants & Agencies (2026)",
        description="The best AI notetakers for consultants and agencies — client-run meetings, NDAs, bot blocking and price.",
        headline="The best AI notetaker for consultants and agencies (2026)",
        dek="Full disclosure: I make MeetMouse. Consultants have two constraints most notetaker reviews ignore, and they narrow the list fast.",
        short_answer="It's often the client's meeting, on their Teams, and their IT removes or blocks notetaker bots. And your NDA may say their information doesn't go to third parties, which makes a notetaker's cloud an awkward question. A tool that hears the call on your own computer and keeps notes there avoids both.",
        short_picks=[
            ("Best for client meetings under NDA", "MeetMouse, free to start (mine)"),
            ("Best bot-free cloud notes", "Granola"),
            ("Best for your own internal calls", "Fathom"),
        ],
        intro=[],
        picks=[
            mm("client meetings under NDA", [
                "Mine. Because it listens through your Mac, it works in the client's Teams, Zoom, Webex or Meet without joining. IT has nothing to block. Transcription and AI run on your laptop, so client information stays there. After each call you get notes with owners, and if you want to send the client a recap, one click makes an encrypted, expiring link with just the notes — never the transcript.",
                "The live coaching helps too: a cue when a stakeholder raised a concern you haven't answered, or when you've been presenting too long.",
            ]),
            pick(GRANOLA, "bot-free notes where confidentiality is relaxed", [
                "Also no bot, and the notes are polished. It processes in the cloud, which some NDAs and client security reviews won't love. Read your contracts.",
            ]),
            pick(FATHOM, "your own firm's internal and sales calls", [
                "Free is free. In a client's meeting, the bot is usually unwelcome.",
            ]),
            pick(OTTER, "long engagements where the client is fine with the cloud", [
                "If you need to search everything anyone said over a months-long engagement, Otter's search is strong.",
            ]),
        ],
        verdict=[
            "Client work under NDA: MeetMouse. Internal calls: Fathom's free plan is fine.",
            "If you write up findings by talking, my other app, <a href=\"https://rhinovoice.app/\">Rhino Voice</a>, turns speech into clean text on your Mac.",
        ],
        today=[
            "Re-read the confidentiality clause in your biggest client contract. Look for \"third parties\".",
            "Ask your next client whether their IT allows notetaker bots. Now you know.",
            "Try MeetMouse on your next client call. It's free for 3 meetings a week, so finding out costs nothing.",
        ],
        faq=[
            ("Can I use an AI notetaker in a client's Teams or Zoom meeting?", "Bot tools have to join the client's meeting and often get blocked. MeetMouse and Granola capture audio on your computer, so they work in any client-run meeting without joining."),
            ("Does a cloud notetaker break my NDA?", "It can, depending on what your NDA says about third parties. MeetMouse keeps transcription and AI on your Mac by default. Check your actual agreements."),
            ("Can I share meeting notes with a client?", "Yes. MeetMouse makes an encrypted, expiring link with only the curated notes — not the transcript or coaching — and you can revoke it anytime."),
            ("How much do AI notetakers cost?", "Fathom is free, Granola is free for 30 days of history and $14/user/month after that, Otter Pro is $16.99/month, and MeetMouse is free for 3 meetings a week, or $20 once for unlimited."),
        ],
        cta_body="Free to start. Works in any client's meeting, and client information stays on your Mac. " + REFUND,
        checked="September 2026",
    ),
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/ai-notetaker-for-coaches",
        label="Best AI notetaker for coaches",
        blurb="Executive, career and business coaches: session notes without a bot — and a coach for the coach.",
        title="Best AI Notetaker for Coaches (2026): Private Session Notes",
        description="The best AI notetakers for executive, career and business coaches — session notes without a bot, client privacy and live feedback on your own coaching.",
        headline="The best AI notetaker for coaches (2026)",
        dek="Full disclosure: I make MeetMouse. Coaching sessions are the worst place for a bot and the cloud, and most notetakers don't tell you anything about your own coaching.",
        short_answer="Clients tell coaches real things: career fears, money, family. A visible bot changes what they say, and a cloud archive of every session is a lot of trust to extend. The best setup keeps sessions off anyone's servers and, ideally, tells you when you're talking more than your client.",
        short_picks=[
            ("Best private session notes plus feedback on your coaching", "MeetMouse, free to start (mine)"),
            ("Best notes if the cloud is fine", "Granola"),
            ("Best for delivery (ums, pace)", "Poised"),
        ],
        intro=[],
        picks=[
            mm("private session notes and a coach for the coach", [
                "Mine. It listens through your Mac, so no bot shows up in your client's Zoom. Sessions are transcribed and summarized on your laptop — nothing uploaded, no account. After each session you get notes with themes and commitments, and next week you can ask what your client said they'd try and jump to the moment.",
                "During the session it keeps you honest: a cue when you've out-talked your client for a stretch, when they raised something and you moved on, or when \"I'll try\" wasn't a real commitment. The rubric is editable, so you can put your own coaching principles in it.",
            ]),
            pick(GRANOLA, "clean notes, if the cloud is fine", [
                "Lovely notes and no bot. Processed in the cloud.",
            ]),
            pick(POISED, "polishing how you sound", [
                "Poised coaches filler words and pace in real time. It doesn't look at the substance of the session.",
            ]),
            pick(FATHOM, "free", [
                "Free and good, but a visible bot in a vulnerable conversation is a lot to ask of a client.",
            ]),
        ],
        verdict=["If your sessions are sensitive and you want to get better as a coach, MeetMouse. If you just want notes and the cloud is fine, Granola."],
        today=[
            "Add one line to your client agreement about how you take notes.",
            "In your next session, count how many times you gave advice before asking a second question.",
            "Try MeetMouse for two weeks of sessions. It's free for 3 meetings a week, so finding out costs nothing.",
        ],
        faq=[
            ("What's the best AI notetaker for coaching sessions?", "MeetMouse if you want sessions to stay on your Mac and live feedback on your own talk time. Granola for bot-free cloud notes. Fathom if you need free."),
            ("Will my client see a bot?", "Not with MeetMouse or Granola — both capture audio on your computer. Fathom, Otter and Fireflies join as a participant. Let clients know you take AI notes either way."),
            ("Can AI help me become a better coach?", "That's the point of MeetMouse's live cues: talk balance, things your client raised that you skipped, and vague commitments, while the session is still happening."),
            ("Is MeetMouse for therapy or clinical notes?", "No. It isn't built as a clinical tool. Licensed clinicians should use something designed for their regulatory requirements."),
        ],
        cta_body="Free to start. No bot in your client's session, and nothing uploaded. " + REFUND,
        checked="September 2026",
    ),
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/meeting-coach-for-managers",
        label="Best meeting coach for managers",
        blurb="Your 1:1s are probably mostly you talking. Tools that fix that in the room.",
        title="Best Meeting Coach for Managers (2026): Better 1:1s in Real Time",
        description="The best AI meeting coaches for managers — live cues in 1:1s and team meetings, talk-time balance and delivery feedback. MeetMouse vs Poised vs notetakers.",
        headline="The best meeting coach for managers (2026)",
        dek="Full disclosure: I make MeetMouse, which coaches you during the meeting. So does Poised, which is good too, at a different thing.",
        short_answer="A 1:1 is supposed to be your report's meeting, and it's easy for it to become yours. It's also the worst place for a visible bot: someone about to say \"I'm thinking about leaving\" doesn't say it in front of a participant named Notetaker. Notetakers remember 1:1s; they don't change them.",
        short_picks=[
            ("Best for better 1:1s and team meetings", "MeetMouse, free to start (mine)"),
            ("Best for presentation delivery", "Poised"),
            ("Best for just remembering follow-ups", "Granola or Fathom"),
        ],
        intro=[],
        picks=[
            mm("the conversation itself: talk balance, skipped concerns, commitments", [
                "Mine. In a 1:1 you get quiet cues only you can see: you've talked most of the last five minutes; they mentioned workload twice and you moved on; \"I'll try\" isn't a commitment — ask what by when. In team meetings it catches when someone got cut off. The rubric is editable.",
                "Your reports' 1:1s stay on your Mac, not in a cloud archive. You get notes with owners after, which makes next week's prep quick.",
            ]),
            pick(POISED, "how you sound: filler words, pace", [
                "If the feedback you keep getting is \"too many ums\" or \"slow down\", Poised is built for exactly that. Cloud subscription.",
            ]),
            pick(GRANOLA, "remembering what was said, no bot", [
                "Great notes. It won't tell you anything about how the conversation went.",
            ]),
            pick(FATHOM, "free notes, bot is fine", [
                "Free and good. A visible bot in 1:1s tends to make people more careful.",
            ]),
        ],
        verdict=["For better 1:1s: MeetMouse. For presentation polish: Poised. For memory only: Granola or Fathom."],
        today=[
            "Before your next 1:1, ask your report to own the agenda.",
            "During it, aim to talk less than a third of the time.",
            "End every 1:1 by saying each commitment out loud with a date.",
            "Try MeetMouse for a week of 1:1s. It's free for 3 meetings a week, so finding out costs nothing.",
        ],
        faq=[
            ("Is there an AI coach for 1:1 meetings?", "Yes. MeetMouse coaches you live during 1:1s — talk balance, concerns you skipped, vague commitments — in an overlay only you see, processed on your Mac."),
            ("Should managers record 1:1s with a bot?", "A visible bot usually makes people less candid. Bot-free tools capture audio on your computer instead. Either way, tell your team how you take notes."),
            ("What's the difference between MeetMouse and Poised?", "Both coach live. Poised focuses on delivery — filler words, pace, energy — on a cloud subscription. MeetMouse focuses on the conversation itself, runs on your Mac, and is free to start ($20 once for unlimited)."),
            ("Can I customize what the coach looks for?", "Yes. MeetMouse's coaching rubric is editable."),
        ],
        cta_body="Free to start. Your team's 1:1s stay on your Mac. " + REFUND,
        checked="September 2026",
    ),
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/ai-notetaker-for-zoom",
        label="Best AI notetaker for Zoom",
        blurb="Zoom AI Companion vs bots vs bot-free apps — it depends on whose meeting it is.",
        title="Best AI Notetaker for Zoom (2026): With and Without a Bot",
        description="The best AI notetakers for Zoom — Zoom AI Companion, Fathom, Otter, Granola, MeetMouse — compared on bots, host permissions, privacy and price.",
        headline="The best AI notetaker for Zoom (2026)",
        dek="Full disclosure: I make MeetMouse. If you host on paid Zoom, the first pick on this page isn't mine, and it's already included in what you pay.",
        short_answer="The right Zoom notetaker comes down to whose meeting it is. If you host on a paid plan, Zoom's own AI Companion is included. In someone else's meeting, bots need the host to let them in, and bot-free apps that hear your computer's audio just work.",
        short_picks=[
            ("Best if you host on paid Zoom", "Zoom AI Companion"),
            ("Best free in any meeting", "Fathom (bot joins by default)"),
            ("Best no-bot, cloud notes", "Granola"),
            ("Best no-bot, nothing uploaded, live coaching", "MeetMouse, free to start (mine)"),
        ],
        intro=[],
        picks=[
            dict(name="Zoom AI Companion", best_for="meetings you host on a paid Zoom plan", price="Included with paid Zoom plans",
                 where="Zoom's cloud; the host controls it", local="No", url="https://www.zoom.com/",
                 body=["No bot, no install, no extra cost on a paid plan. The catches: Zoom only, the host controls it, and your data sits in Zoom's cloud. Use what you've got first."]),
            pick(FATHOM, "free notes in anybody's Zoom", ["Joins any meeting the host lets it into and writes excellent summaries. Everybody sees it."]),
            pick(OTTER, "recurring meetings you'll search later", ["Live transcript and a searchable history. A bot joins each one."]),
            pick(GRANOLA, "no bot, cloud notes", ["Hears Zoom through your computer, so nothing joins and nothing gets stuck in a waiting room."]),
            mm("no bot, nothing uploaded, and help during the call", [
                "Mine. It listens through your Mac, so it works in any Zoom — yours, a client's, a webinar — with nothing for the host to block. It coaches you during the call from your own Mac, in an overlay that stays out of your screen share. Notes and a chat after.",
                "It doesn't use Zoom's API, so it doesn't pull participant names from Zoom; it tells speakers apart by voice. Mac only.",
            ]),
        ],
        verdict=["Host on paid Zoom and just want summaries: AI Companion. Want help in the meeting, in any Zoom, with nothing uploaded: MeetMouse."],
        today=[
            "If you host on paid Zoom, turn on AI Companion today. You're already paying for it.",
            "Check whether your company blocks third-party bots in Zoom. Many do.",
            "Try MeetMouse in your next Zoom you don't host. It's free for 3 meetings a week, so finding out costs nothing.",
        ],
        faq=[
            ("What's the best AI notetaker for Zoom?", "If you host on a paid plan, Zoom AI Companion is included. For any meeting: Fathom is free (bot joins by default), Granola is bot-free with cloud notes, and MeetMouse is bot-free, on-device and coaches you live, free for 3 meetings a week."),
            ("Can I use an AI notetaker in a Zoom I don't host?", "Bot tools need the host to let them in. Bot-free apps like MeetMouse and Granola capture audio on your computer, so they work in any meeting you can hear."),
            ("Is there a Zoom notetaker without a bot?", "Yes: Zoom AI Companion (host-controlled), Granola and MeetMouse. MeetMouse is the only one that keeps everything on your device."),
            ("Does the MeetMouse overlay show up when I share my screen?", "No. It's excluded from screen shares and recordings."),
        ],
        cta_body="Free to start. Works in any Zoom, no bot, nothing uploaded. " + REFUND,
        checked="September 2026",
    ),
    # ─────────────────────────────────────────────────────────────
    dict(
        slug="best/ai-notetaker-for-financial-advisors",
        label="Best AI notetaker for financial advisors",
        blurb="Your clients tell you their balances, inheritances and divorces. Here's where each tool sends that.",
        title="Best AI Notetaker for Financial Advisors (2026): Privacy First",
        description="The best AI notetaker for financial advisors: advisor-built CRM tools vs on-device notes, compared on client privacy, records, bots and price.",
        headline="The best AI notetaker for financial advisors (2026)",
        dek="Full disclosure: I make MeetMouse, and I'm not a compliance officer. Your firm's recordkeeping rules come first, so read this, then go ask them.",
        short_answer="The best AI notetaker for a financial advisor depends on one question: does your firm need the notes in a central system? If yes, use an advisor-built tool like Jump or Zocks that writes into your wealth CRM, and let compliance approve it. If you're independent and mostly want your client's balances, health news and family drama kept off other people's servers, use a notetaker that runs on your own computer. MeetMouse does that on a Mac, free for 3 meetings a week.",
        short_picks=[
            ("Best for firms that need CRM sync and central records", "Advisor-built tools like Jump or Zocks"),
            ("Best for keeping client finances off anyone's cloud", "MeetMouse, free to start (mine)"),
            ("Best general notetaker your firm may already approve", "Fathom or Granola on a business plan"),
        ],
        intro=[
            ("What makes advisor meetings different", [
                "A sales call is about a deal. A review meeting is about someone's whole life: the account balances, the inheritance from a parent who just died, the divorce, the diagnosis that changes the retirement plan. People say these things out loud to you because they trust you. Every notetaker sends that conversation somewhere, and the honest way to pick one is to ask where.",
                "There are only three places it can go: a vendor built for advisors, a general notetaker's cloud, or nowhere at all because it stays on your laptop. All three can be the right answer.",
            ]),
            ("Four questions to ask before a client meeting", [
                "Does the audio or transcript leave my computer, and which companies see it? Does a bot show up on my client's screen? Do the notes need to land in my CRM or my firm's archive to count as a record? Can I delete a meeting for real if a client asks?",
                "If your firm treats meeting notes as records you must keep, that answer alone points you to an advisor-built tool or to whatever compliance already approved. Don't guess on this one.",
            ]),
        ],
        picks=[
            dict(name="Advisor-built tools (Jump, Zocks)", best_for="firms that need wealth-CRM sync and central records",
                 price="Subscription; see each vendor's pricing", where="Vendor cloud", local="No",
                 body=["Built around how advisors actually work: prep before the meeting, notes into wealth CRMs after it, and a record your firm can find later. If your firm needs a central archive, start here, and bring compliance into the trial.",
                       "The trade is the one every cloud tool makes: your client's words live on the vendor's servers. For most firms that's fine once it's been reviewed. Just don't sign up on a personal card and start recording client reviews."]),
            mm("independent advisors who want notes without uploading client data", [
                "Mine. It listens through your Mac, so no bot shows up on your client's screen and nobody sees a recording notice. Transcription and the default AI run on your laptop, and it keeps working with Wi-Fi off. When the meeting ends you get notes with action items, and you can ask a saved meeting what a client said about, say, the Roth conversion and jump to that moment.",
                "During the meeting, it can flag a worry your client raised that you didn't come back to. That's the moment a client remembers. What it doesn't do: CRM sync or firm-level archiving. If you need either, it's a personal tool next to your system of record, not a replacement for it.",
            ]),
            pick(FATHOM, "general notes, if your firm has approved it", [
                "A good, generous product, not built for advisor recordkeeping. A bot joins by default; Fathom has bot-free capture in beta. Use a plan your firm has reviewed, not a personal free account.",
            ]),
            pick(GRANOLA, "bot-free notes, if your firm has approved it", [
                "No bot on the call and very good notes. The notes are written with cloud AI, so the same rule applies: firm-approved plan only.",
            ]),
        ],
        verdict=[
            "If your firm needs CRM sync and central records, use an advisor-built tool and let compliance pick between them.",
            "If you're independent and you don't want a client's finances in anyone's cloud, use MeetMouse. You'll still copy the action items into your CRM yourself, which takes a minute and is the price of nothing being uploaded.",
            "If you dictate client letters and follow-up emails too, my other app <a href=\"https://rhinovoice.app/\">Rhino Voice</a> does that on-device as well.",
        ],
        today=[
            "Ask compliance two questions: which note-taking tools are approved, and do AI meeting notes count as records you must keep?",
            "List every place client meeting notes live today: email, CRM, legal pads, a notetaker's cloud. Each one is a place they can leak from.",
            "Tell clients you take AI notes, whatever tool you use.",
            "If you're independent, try MeetMouse on a week of internal calls, then on client meetings once you trust it.",
        ],
        faq=[
            ("What is the best AI notetaker for financial advisors?", "If your firm needs notes synced into a wealth CRM and kept as central records, an advisor-built tool like Jump or Zocks, approved by compliance. If you're independent and want client details kept off other companies' servers, MeetMouse, which runs transcription and AI on your Mac and is free for 3 meetings a week."),
            ("Can financial advisors use AI notetakers?", "Many do, but recordkeeping and privacy rules vary by firm and regulator, so ask compliance first. Advisor-built tools focus on CRM and records; MeetMouse keeps client data on your Mac."),
            ("Which AI notetaker keeps client financial data private?", "MeetMouse processes transcription and its default AI on your Mac and works with Wi-Fi off, so client details aren't uploaded. If you add your own Claude or OpenAI key, meeting text goes to that provider, so leave it on local for client meetings."),
            ("Does MeetMouse sync to Redtail, Wealthbox or Salesforce?", "No. Notes stay on your Mac. You can copy them into your CRM or share them through an encrypted, expiring link."),
            ("Does a bot join client meetings?", "Not with MeetMouse or Granola, which capture audio on your computer. Otter and Fireflies join as a visible participant, and Fathom does by default."),
            ("Is MeetMouse compliant with SEC or FINRA rules?", "I can't tell you that, and you should be wary of any notetaker that says yes without your compliance team in the loop. MeetMouse has no compliance certifications. What it does is keep the conversation on your Mac by default, which is a different thing."),
        ],
        cta_body="Free to start. Client finances stay on your Mac. " + REFUND,
        checked="October 2026",
    ),
]
