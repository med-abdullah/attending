# Changelog

## 1.2.0

- **Question blocks:** set a block (40 questions in 60 minutes to start) and the notch keeps your pace: "Q18 of 40 · 1 ahead", green, amber or red. It follows UWorld, AMBOSS and similar pages by reading the question number (with Accessibility allowed); otherwise ⌃⌘→ and ⌃⌘← or the hover buttons move between questions. When it ends, log what you missed and add the questions to your bank in one step.
- **Weak spots:** tap the subjects you missed after a block (or any time). The Study tab shows your three weakest this week, and **Quiz me** asks Gemini (or your default AI) for board-style questions on them.
- **Lecture day:** the Today card lists today's classes (checked off as each ends) and then tomorrow's, with pre-reads found in the event notes and the next chapter in your tracker. At 8 PM the notch sums up tomorrow: "Tomorrow: 3 classes, 2 pre-reads". Pick the calendar that holds your classes in Settings › Study.
- **Exam week can turn itself on** (optional, in Settings › Boards) in the last 7 days before an exam on your tracker or Boards card, and off after it. The closed notch shows the countdown, the hover preview shows just the exam, Anki and today's goal, and alerts that can wait (agents finishing, updates, usage) hold off. Turn it off and it stays off for that exam.
- **Codex approvals in the notch:** Settings › Agents › Codex approvals › Connect adds Attending as Codex's permission hook. Codex asks you to trust it once; then Allow or Deny from the notch, or let Codex ask as usual.
- **What's new after each update:** the first launch after an update shows this version's highlights. Reopen it from Settings › Updates or the menu bar menu.
- **Setup guides:** step-by-step instructions for the reading tracker, Canvas, calendars, Apple Reminders, Anki, question blocks, prayer times, and Claude Code and Codex, in each section of Settings and together under Settings › Setup guides.
- **Fix:** the island no longer opens over Mission Control or gets stuck after it, and closes reliably whenever the pointer leaves it.
- **Shia prayer times:** Shia Ithna-Ashari (Jafari, Leva Institute, Qum) and Tehran methods. Maghrib comes after the redness (4° below the horizon), Dhuhr and Asr stay due until sunset and Maghrib and Isha until Islamic midnight, with sunset and midnight on the Salah card and "ending soon" alerts timed to them. Checked against Aladhan.
- **Canvas:** connect with a personal access token for announcements from your current courses (a drop-down when a new one is posted), assignments and quizzes due in the next two weeks, and your Canvas calendar, added to Calendars automatically. On Home and in Study.
- **Apple Reminders:** what's due today and overdue, plus what's coming up, on Home. Click to check one off; type to add one for today. Turn on in Settings › Reminders.
- **Fewer download and export dings:** render caches, optimized media, proxies and saves under 20 seconds no longer alert; a render that pauses isn't called finished until it's quiet for 20 seconds, and never dings twice; files that finish together share one alert; there's no sound while a video editor is in front, and alerts held while the island was hidden show without a sound. Settings › Live activities has separate switches for download alerts, export alerts and their sound.
- **Quieter for new users:** Screen Time and the distraction guard now start off. The setup window has a switch for each (and a Connect button for Codex). Anyone who already had them keeps them.

## 1.1.1

- **Drag the island anywhere:** press and drag it; when you let go it glides to the nearest spot (under the notch, top left, top right or bottom center). Thanks to a commenter for the idea.
- **Fix:** the volume display shows again while a video is full screen. When the island steps aside, the volume and brightness keys go to macOS and its own display appears.
- **Fix:** the music visualizer no longer trips a threading warning while audio plays.

## 1.1.0

- **Boards countdown:** COMLEX, USMLE, shelf and block exams with presets, a dedicated period, days off and study days; a question-bank pace with quick logging; practice exams with a score trend; milestone, checklist, exam-morning and "you did it" moments; a calm mode; a countdown in the closed notch; and a shareable countdown card.
- **Exam week mode**, a bedtime nudge before exams, a **score tracker**, water-and-stretch reminders, **Anki card of the day**, **quick lookup**, a **weekly recap** you can share, **screen time** and a **distraction guard** during focus.
- **Calendars:** connect Google and Outlook (macOS accounts or a private iCal link), with reminders before each class.
- **Salah:** Jummah and Surah Al-Kahf reminders, the Hijri date and the Qibla direction.
- **Agents:** sessions from the ChatGPT and Codex apps, real session names, a cleaner Agents tab, answers to Claude's questions and plan approvals from the notch, a check when ChatGPT or Codex finishes, and a heads-up when Codex asks a question.
- **Ask AI:** Gemini, instant switching between providers, a check when an answer is ready, and a switch to turn off any provider.
- **Utilities:** keep awake (automatic while agents work), quit apps when their last window closes, window snapping, quick notes, a camera-in-use dot, Shelf file conversion, PDF merging, photos to PDF, copy text from images and Add to Zotero, clean screen mode, moving the island anywhere on the screen, and choosing which tabs show (Agents is off by default; its questions and approvals appear on Home).
- **Teleprompter:** a Prompter tab for your script; it scrolls right under the camera at the pace you set, pauses on hover, moves with the trackpad, and is hidden from screen sharing and recordings.
- **Stays out of the way:** the island hides while something is full screen and while apps you pick are in front (DaVinci Resolve and Final Cut to start); alerts wait until it's back.
- **Welcome and setup:** a first-launch welcome (the stethoscope draws itself and the heartbeat starts), then a checklist for Accessibility, Calendar, Location and Claude Code with live status and one button each. Claude Code now connects from inside the app, with no script. Reopen it from Settings › Help.
- **Easier installs:** a DMG to drag into Applications, an offer to move Attending to Applications when it's run from Downloads, and Settings › Help › Report a problem, which fills in the details for you.
- **Fixes:** Spotify add to playlist and likes (Spotify's API changed), and the prayer time no longer hides under the notch on hover.

## 1.0.0

First public release.

- **Notch island:** the collapsed mark (a stethoscope that turns into a live ECG while agents work), a hover glance and a full panel, with smooth spring animation.
- **Study:**
  - Google Sheets reading trackers with check-off from the notch and a daily page goal.
  - Anki decks, due counts and streak.
  - Focus timer and study sessions.
  - Exam countdowns.
- **Salah:** prayer times calculated on your Mac, prayed check-offs, a streak, and alerts at each prayer and before one ends.
- **Music:** Now Playing for any app with a live visualizer. Spotify like, add to playlist, Smart Shuffle indicator and Up Next queue.
- **AI:**
  - Claude and ChatGPT in the notch.
  - A Claude usage meter.
  - Claude Code and Codex session monitoring, with allow-once or deny approvals.
- **Everyday:**
  - Drag to AirDrop, Shelf or Google Drive.
  - Screenshot drops and clipboard history with pins.
  - Camera with photos.
  - Volume, brightness and battery displays, plus AirPods battery.
  - Download and export progress, meeting countdowns, drive eject, weather, calendar and Outlook unread.
