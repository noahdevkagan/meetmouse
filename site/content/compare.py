"""Structured "MeetMouse vs X" pages. Rendered by site/build.py.

Older comparisons live as fragments in site/articles/; new ones should be
added here so the table, short answer and schema can't drift.
"""

COMPARE = [
    dict(
        slug="compare/meetmouse-vs-tldv",
        competitor="tl;dv",
        blurb="A recorder built for clips vs a coach that works during the call.",
        title="MeetMouse vs tl;dv (2026): Honest Comparison From the Guy Who Makes MeetMouse",
        description="MeetMouse vs tl;dv: clip-sharing meeting recorder vs a $20 on-device live coach. Bots, privacy, pricing, and who should use which.",
        headline="MeetMouse vs tl;dv: clips after the call vs cues during it",
        dek="Disclosure: MeetMouse is mine. tl;dv is good at something I don't do at all, so this is an easy page to be honest on.",
        short_answer="If your team runs on \"watch these 40 seconds\", get tl;dv — nobody clips meetings better. MeetMouse doesn't record video or make clips. It coaches you while the call is happening, on your Mac, and writes notes after. Different jobs.",
        pick_them="your team needs to see meetings: video, clips, highlights shared in Slack.",
        pick_mm="your problem is how the meeting goes, and you want nothing uploaded.",
        rows=[
            ("Job", "Coach you live; notes after", "Record, clip and share moments"),
            ("Price", "$20 one time", "Free (data kept up to 3 months); Pro $29/seat/mo"),
            ("Bot joins your call", "No", "Yes"),
            ("Video recording", "No", "Yes"),
            ("Where your meeting goes", "Stays on your Mac by default", "tl;dv's cloud"),
            ("Platforms", "Mac only (macOS 14.2+)", "Web; works with Zoom, Meet, Teams"),
        ],
        sections=[
            ("Where tl;dv wins", [
                "Clips. Hearing the customer say it in their own voice beats any summary. For product and research teams, this is the feature.",
                "Video. Demos, screen shares, the face they made when you said the price.",
                "Free to start: unlimited recordings, with a 3-month shot clock.",
            ]),
            ("Where MeetMouse wins", [
                "Timing. A clip of you burying your ask is still a buried ask. MeetMouse taps you while you can fix it.",
                "No bot, and no recording on anyone's server. Nothing leaves your Mac unless you choose to add your own AI key.",
                "$20 once. No shot clock.",
            ]),
            ("My honest verdict", [
                "Your team needs to see meetings? Get tl;dv. Your problem is how the meeting goes? That's what I built MeetMouse for, and it runs next to tl;dv with no conflict.",
            ]),
        ],
        faq=[
            ("Is tl;dv free?", "tl;dv has a free plan with unlimited recordings, AI notes on 10 meetings, and data kept up to 3 months. Pro is $29/seat/month. MeetMouse is $20 one time."),
            ("Does tl;dv join as a bot?", "Yes, tl;dv's recorder joins the meeting. MeetMouse listens through your Mac, so nothing joins."),
            ("Does MeetMouse record video or make clips?", "No. MeetMouse works from audio, coaches you live and writes notes after. For video clips, tl;dv is the better tool."),
            ("Can I use MeetMouse and tl;dv together?", "Yes. tl;dv records for the team; MeetMouse coaches you during the call."),
        ],
        checked="September 2026",
    ),
    dict(
        slug="compare/meetmouse-vs-gong",
        competitor="Gong",
        blurb="Enterprise revenue intelligence vs a $20 coach for the rep on the call.",
        title="MeetMouse vs Gong (2026): Honest Comparison From the Guy Who Makes MeetMouse",
        description="MeetMouse vs Gong: enterprise revenue intelligence vs a $20 on-device live sales coach. What each does, who it's for, and when you'd run both.",
        headline="MeetMouse vs Gong: the sales org's system vs the rep's coach",
        dek="Disclosure: MeetMouse is mine. Comparing a $20 Mac app to Gong is a little funny — they're not the same size of thing. But people search it, so here's the honest version.",
        short_answer="If you're a sales leader with RevOps and a budget, Gong is the category leader and MeetMouse isn't trying to replace it. MeetMouse is for the rep on the call: live cues when the buyer raises an objection you skate past. Many reps should run both.",
        pick_them="you need forecasting, deal risk, a call library and manager coaching workflows across a team.",
        pick_mm="you carry a quota and want help on the call you're on right now, without an enterprise contract.",
        rows=[
            ("Who it's for", "The individual on the call", "Sales leaders, RevOps, the whole org"),
            ("When it helps", "During the call; notes after", "Mostly after: reviews, analytics, forecasting"),
            ("Price", "$20 one time", "Custom (enterprise)"),
            ("Records calls", "No recording archive", "Yes"),
            ("CRM integration", "None", "Deep"),
            ("Where your calls go", "Stays on your Mac by default", "Gong's cloud"),
        ],
        sections=[
            ("Where Gong wins", [
                "Org-wide visibility: forecasts, deal risk, pipeline. MeetMouse doesn't do any of this.",
                "The call library. New reps learn from the best calls; managers coach from real examples.",
                "CRM and workflow. It plugs into how a sales org runs.",
            ]),
            ("Where MeetMouse wins", [
                "Timing. A manager reviewing your call next week doesn't save this deal. A cue at the moment the objection comes up can.",
                "Price. A rep can buy it without a procurement cycle.",
                "No bot, no cloud, and an editable rubric you can load with your own discovery questions.",
            ]),
            ("My honest verdict", [
                "Running a sales org? Gong. Carrying a quota? MeetMouse, next to whatever your team records with.",
            ]),
        ],
        faq=[
            ("Is MeetMouse a Gong alternative?", "For a sales org's analytics and forecasting, no. For an individual rep who wants live coaching during calls without an enterprise contract, yes."),
            ("Does Gong coach you in real time?", "Gong is built mainly around recording calls and coaching from them afterward. MeetMouse shows live cues during the call in an overlay only you see."),
            ("How much does Gong cost?", "Gong uses custom enterprise pricing. MeetMouse is $20 one time."),
            ("Can I run MeetMouse and Gong together?", "Yes. Gong records for the org; MeetMouse listens through your Mac and coaches you live."),
        ],
        checked="September 2026",
    ),
    dict(
        slug="compare/meetmouse-vs-zoom-ai-companion",
        competitor="Zoom AI Companion",
        blurb="The notes you already pay for vs live coaching in any meeting app.",
        title="MeetMouse vs Zoom AI Companion (2026): Honest Comparison",
        description="MeetMouse vs Zoom AI Companion: built-in Zoom meeting summaries vs a $20 on-device live coach that works in any meeting app.",
        headline="MeetMouse vs Zoom AI Companion",
        dek="Disclosure: MeetMouse is mine. And Zoom AI Companion is the easiest recommendation on this site if you host on Zoom — you're already paying for it.",
        short_answer="If you host on a paid Zoom plan, use AI Companion for summaries. MeetMouse works in every meeting app, including other people's Zooms, coaches you during the call, and keeps everything on your Mac.",
        pick_them="you host on paid Zoom and just want summaries.",
        pick_mm="you want help during the meeting, in any app or anyone's Zoom, with nothing uploaded.",
        rows=[
            ("Job", "Live coaching; notes after", "Summaries inside Zoom"),
            ("Price", "$20 one time", "Included with paid Zoom plans"),
            ("Works in meetings you don't host", "Yes", "Host decides"),
            ("Works outside Zoom", "Yes — any app on your Mac", "No"),
            ("Where your meeting goes", "Stays on your Mac by default", "Zoom's cloud"),
            ("Coaches you during the call", "Yes", "No"),
        ],
        sections=[
            ("Where Zoom AI Companion wins", [
                "You already have it: no install, no extra cost on a paid plan.",
                "Built into Zoom, so it knows who's in the meeting. And it runs everywhere Zoom does; MeetMouse is Mac-only.",
            ]),
            ("Where MeetMouse wins", [
                "Other people's meetings: a client's Zoom, a Teams call, a FaceTime. It works anywhere you can hear.",
                "Live coaching. A summary doesn't stop you from monologuing. A cue does.",
                "Nothing uploaded to Zoom's cloud or anyone else's.",
            ]),
            ("My honest verdict", ["Host on paid Zoom and want summaries? Turn on AI Companion. Want help in the meeting itself? MeetMouse."]),
        ],
        faq=[
            ("Is Zoom AI Companion free?", "It's included with paid Zoom plans at no extra cost. It isn't available on free Zoom accounts."),
            ("Does Zoom AI Companion work in meetings I don't host?", "The host controls whether it's on. MeetMouse listens through your Mac, so it works in any meeting you can hear."),
            ("Does Zoom AI Companion coach you during the meeting?", "It focuses on summaries and answering questions about the meeting. MeetMouse shows live coaching cues while you talk."),
            ("Does MeetMouse only work with Zoom?", "No. It works with Zoom, Google Meet, Teams, FaceTime, Slack huddles and anything else that plays through your Mac."),
        ],
        checked="September 2026",
    ),
    dict(
        slug="compare/meetmouse-vs-macwhisper",
        competitor="MacWhisper",
        blurb="Two on-device Mac apps: a transcription tool vs a live meeting coach.",
        title="MeetMouse vs MacWhisper (2026): Two Private Mac Apps Compared",
        description="MeetMouse vs MacWhisper: both run on-device on your Mac. One transcribes audio files, the other coaches you live in meetings.",
        headline="MeetMouse vs MacWhisper: transcription tool vs meeting coach",
        dek="Disclosure: MeetMouse is mine. MacWhisper is one of the few apps I'd call a cousin — local-first, one-time purchase, Mac-native. I like it.",
        short_answer="Both keep your audio on your Mac. MacWhisper is the best tool for turning recordings into accurate text. MeetMouse is for live meetings: it coaches you during the call and writes notes after.",
        pick_them="you transcribe interviews, lectures or podcasts from recordings.",
        pick_mm="your job is meetings and you want to get better at them without uploading anything.",
        rows=[
            ("Job", "Coach live meetings; notes after", "Transcribe audio files"),
            ("Price", "$20 one time", "Free tier; one-time Pro license"),
            ("Runs on-device", "Yes (local AI by default)", "Yes"),
            ("Live coaching during calls", "Yes", "No"),
            ("Meeting notes with owners", "Yes", "Light"),
            ("Platform", "Mac (macOS 14.2+)", "Mac"),
        ],
        sections=[
            ("Where MacWhisper wins", [
                "Transcripts of recordings — interviews, lectures, podcasts, voice memos. This is its whole game and it's great at it.",
                "Model choice, subtitles and exports, for people who work with transcripts as the output.",
            ]),
            ("Where MeetMouse wins", [
                "It works during the meeting: cues while you can still act on talk balance, skipped concerns and vague commitments.",
                "Meeting output, not just text: topics, decisions, next steps with owners, and a chat that cites timestamps.",
                "Built for calls: captures your mic and the other side together, with speaker separation on Apple Silicon.",
            ]),
            ("My honest verdict", ["Recordings that need to become text: MacWhisper. Meetings you want to get better at: MeetMouse. Plenty of people should own both."]),
        ],
        faq=[
            ("Is MeetMouse like MacWhisper?", "Both are private Mac apps that run on-device. MacWhisper transcribes audio files; MeetMouse coaches you live during meetings and writes notes afterward."),
            ("Do MeetMouse and MacWhisper work offline?", "Yes. MeetMouse needs a one-time model download, then works with Wi-Fi off."),
            ("Which is better for meeting notes?", "MeetMouse — it's built for meetings, with notes, owners and live coaching. MacWhisper is better for transcribing recordings."),
            ("How much do they cost?", "MacWhisper has a free version and a one-time Pro license. MeetMouse is $20 one time."),
        ],
        checked="September 2026",
    ),
]
