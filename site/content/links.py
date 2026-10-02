"""The one list of every content page, in hub order. Hubs, "More guides"
blocks, llms.txt and the site check all read from here, so a page can't be
published without also being linked. Structured pages (best.py, compare.py)
add themselves; freeform pages in site/articles/ are listed here.
"""

# (href, label, one-line blurb)
BLOG = [
    ("/blog/private-ai-meeting-notes", "Private AI meeting notes: the complete guide", "The three questions that matter — bot, cloud, access — and how every tool scores on them."),
    ("/blog/ai-notetaker-without-bot", "AI notetakers that don't join your call as a bot", "How bot-free capture works, who does it, and the honest trade-offs of each."),
    ("/blog/do-ai-notetakers-record-your-calls", "Do AI notetakers record your calls?", "The audit to forward to your security team: recordings, transcripts, retention, and who can see them."),
    ("/blog/free-granola-alternatives", "Free Granola alternatives: the 5 best options in 2026", "The 5 best options once Granola's 30-day free history runs out, ranked, with prices."),
    ("/blog/fathom-alternatives", "The 5 best Fathom alternatives in 2026", "Ranked, with prices, best-for lines and honest trade-offs, from a competitor."),
    ("/blog/otter-alternatives", "The 5 best Otter.ai alternatives in 2026", "Ranked, with prices, best-for lines and honest trade-offs, from a competitor."),
    ("/blog/fireflies-alternatives", "The 5 best Fireflies.ai alternatives in 2026", "Ranked, with prices, best-for lines and honest trade-offs, from a competitor."),
]

# Freeform "MeetMouse vs X" pages (structured ones come from compare.py).
MM_VS_ARTICLES = [
    ("/compare/meetmouse-vs-granola", "MeetMouse vs Granola", "Notes after the meeting vs coaching during it. Different jobs — many people should run both."),
    ("/compare/meetmouse-vs-fathom", "MeetMouse vs Fathom", "Fathom is the best free notetaker, full stop. Here's what it can't do."),
    ("/compare/meetmouse-vs-otter", "MeetMouse vs Otter.ai", "A searchable archive of every meeting vs actually fixing the meeting you're in."),
    ("/compare/meetmouse-vs-fireflies", "MeetMouse vs Fireflies.ai", "A CRM-connected machine for sales teams vs a private coach for one person: you."),
    ("/compare/meetmouse-vs-poised", "MeetMouse vs Poised", "The closest matchup on this site: two real-time coaches, one big difference — the cloud."),
]

# Third-party head-to-heads. Each pitches MeetMouse in its last section.
X_VS_Y = [
    ("/compare/granola-vs-fathom", "Granola vs Fathom", "No bot, or no bill — pick which cost hurts less."),
    ("/compare/granola-vs-otter", "Granola vs Otter", "The bot-free new way vs the searchable old guard."),
    ("/compare/granola-vs-fireflies", "Granola vs Fireflies", "A quiet notebook for you, or a recording machine for your sales team?"),
    ("/compare/granola-vs-tldv", "Granola vs tl;dv", "Written notes with no bot, or video clips with one."),
    ("/compare/fathom-vs-fireflies", "Fathom vs Fireflies", "The best free notetaker vs the integration machine."),
    ("/compare/fathom-vs-tldv", "Fathom vs tl;dv", "Two free bots. One gives you better summaries, the other better clips."),
    ("/compare/otter-vs-fathom", "Otter vs Fathom", "The archive veteran vs the free favorite — and the part neither fixes."),
    ("/compare/otter-vs-fireflies", "Otter vs Fireflies", "An archive for you, or a machine for your team's managers?"),
]

# Sister site. Link to it where the reader's job is dictation, not meetings.
RHINO = ("https://rhinovoice.app/", "Rhino Voice", "Private Mac dictation by the same maker: hold a key, talk, clean text at your cursor. $20 once, on-device.")
RHINO_GUIDES = ("https://rhinovoice.app/best", "Dictation app guides on rhinovoice.app")
