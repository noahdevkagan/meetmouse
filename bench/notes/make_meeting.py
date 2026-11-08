"""Made-up ~50-minute two-speaker meeting. All names, companies and numbers are invented.
Key facts (M1-M6) sit in the middle third, which the current 32K-char review trim removes."""
import random

random.seed(7)
ME, THEM = "You", "Marta"

filler_topics = {
    "intro": [
        "Sorry, I was a minute late, the previous call ran over.",
        "No worries, I just got my coffee anyway.",
        "How was the offsite last week, did the team get anything out of it?",
        "It was good. Mostly planning, a little too many slides, but people liked the walk on the second afternoon.",
        "We tried something similar in the spring and the walk was the only part anyone remembered.",
        "That sounds about right. The slides were mine, so I will take the blame for those.",
        "Before we get going, did you see the note about the building being closed on Friday?",
        "I did. We will all be remote that day, which is fine, nobody had anything in person planned.",
    ],
    "support": [
        "Support volume has been steady, a little up after the last release but nothing alarming.",
        "Most of the new tickets are people asking where the export button moved to.",
        "We should probably add a small banner for that, it is the same question again and again.",
        "Agreed, I think the help article exists but nobody finds it from inside the app.",
        "The response time is still under four hours on weekdays, weekends are slower.",
        "Do we know if the weekend tickets are mostly from the bigger accounts or the small ones?",
        "Mostly small ones, honestly. The bigger accounts tend to email their account manager directly.",
        "That makes sense. Let us keep an eye on it but I do not think it needs a change yet.",
        "One customer wrote a really long thread about keyboard shortcuts, it was kind of charming.",
        "I saw that. He had a whole list. Some of them are good ideas, to be fair.",
    ],
    "hiring": [
        "On hiring, we have two designers in the final round and one backend person still interviewing.",
        "The backend candidate did well on the system design part but was quieter in the team chat round.",
        "Quiet is fine as long as they ask questions when they are stuck.",
        "That was my thought too. I would rather have someone careful than someone loud.",
        "The designers are both strong, it might come down to who can start sooner.",
        "Let us not rush it though. A two week difference in start date is not worth a worse fit.",
        "Fair. I will set up one more conversation with each so the team can meet them informally.",
        "Good. Keep it short, thirty minutes is plenty for that kind of chat.",
    ],
    "office": [
        "The new desks finally arrived, so the second floor actually looks like an office now.",
        "Are people using it, or is it still mostly empty on Mondays?",
        "Tuesdays and Wednesdays are busy, Mondays and Fridays are pretty quiet.",
        "That is the pattern everywhere I think. I would not fight it.",
        "Someone asked about better coffee again, which I am choosing to treat as a culture issue.",
        "Ha. Put it on the list, it is cheaper than most of the other requests.",
        "The meeting rooms are still the main complaint, there are not enough small ones.",
        "We could split the big room with a divider, that was suggested before.",
    ],
    "misc": [
        "I keep meaning to ask, did the invoice from the printing company ever get sorted?",
        "Yes, that was paid last week, it was just stuck waiting for a purchase order number.",
        "Good, I did not want that hanging around another month.",
        "Also the newsletter went out on Thursday and the open rate was about the same as usual.",
        "Same as usual is fine. Nobody expects the newsletter to change the world.",
        "Let me check my notes, I think I had one more small thing for this part.",
        "Take your time.",
        "No, that is everything for that section, we can move on.",
        "Okay. I think we are on the same page there.",
        "Right, makes sense to me.",
    ],
}

# Middle facts. These must be caught for the notes to be useful.
middle = [
    (THEM, "Okay, the big one. Pricing for Lanternly Teams. We went back and forth on this for weeks, so let us just decide it today."),
    (ME, "Agreed. Where did the finance review land?"),
    (THEM, "Finance is comfortable with fourteen dollars per seat per month for Teams, with a five seat minimum. That is the number I would like us to commit to."),
    (ME, "Fourteen per seat, five seat minimum. I am fine with that. So that is decided, fourteen dollars per seat per month."),
    (THEM, "Great. Second thing, the launch date. Engineering asked for more time on the migration, so we are moving launch from March third to March twenty fourth."),
    (ME, "March twenty fourth works. I would rather have three extra weeks than a shaky migration."),
    (THEM, "And for the migration script itself, Teodor has agreed to own it end to end, including the rollback plan. He will have a first version by February tenth."),
    (ME, "Good, Teodor owns the migration script, first version February tenth. I will tell the support team so they know who to ask."),
    (THEM, "Budget for the outside contractor who helps with the data import is capped at eighteen thousand dollars. If it goes over, it comes back to the two of us."),
    (ME, "Eighteen thousand cap, noted. That feels right for the scope we talked about."),
    (THEM, "We also decided, and I want this written down, that the Android beta is paused until the third quarter. We do not have the people to do it properly before then."),
    (ME, "Yes, pause Android until Q3. It is the right call even if a few customers will be disappointed."),
    (THEM, "The one thing still open is data retention. Legal has not said whether we can keep import logs for ninety days. We cannot finish the settings page until they answer."),
    (ME, "So ninety day retention is an open question waiting on legal. I will chase them this week, I can do that by Thursday."),
]

tail_facts = [
    (THEM, "To wrap up, can you send the launch summary to the wider team?"),
    (ME, "Yes, I will send the launch summary to the whole team tomorrow morning."),
    (THEM, "And I will book the review with the board for the week after launch."),
    (ME, "Perfect. Thanks Marta, this was a productive one."),
]


def block(topics, target_chars):
    out, n, who = [], 0, THEM
    while n < target_chars:
        topic = random.choice(topics)
        k = random.randint(2, 4)
        text = " ".join(random.sample(filler_topics[topic], k))
        out.append((who, text))
        n += len(text) + 10
        who = ME if who == THEM else THEM
    return out


turns = []
turns += block(["intro", "support", "misc"], 13_000)       # opening, kept by trim
turns += block(["hiring", "office", "misc"], 3_000)        # pre-middle filler
turns += middle
turns += block(["support", "office", "misc"], 4_000)       # post-middle filler, also trimmed
turns += block(["hiring", "support", "office", "misc"], 23_000)  # tail filler, kept
turns += tail_facts

text = "\n".join(f"{s}: {t}" for s, t in turns)
open("meeting.txt", "w").write(text)
mid_text = "\n".join(f"{s}: {t}" for s, t in middle)
start = text.index(mid_text)
print("chars", len(text), "middle starts", start, "ends", start + len(mid_text),
      "kept head<=10000, tail>=", len(text) - 22_000)
