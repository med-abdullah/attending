import AppKit
import SwiftUI

/// Step-by-step setup for everything that connects to something outside Attending. Each
/// guide shows in its own Settings section and all of them under Settings › Help.
struct Guide: Identifiable {
    struct Action { var title: String; var symbol: String; var run: @MainActor () -> Void }
    var id: String
    var title: String
    var steps: [String]
    var note: String?
    var actions: [Action] = []
}

@MainActor enum Guides {
    static func open(_ link: String) { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }

    static let tracker = Guide(id: "tracker", title: "Reading tracker (Google Sheets)", steps: [
        "Your tracker is a Google Sheet with \"Tracker\" or \"PBL\" in its name, like \"Exam 3 Reading Tracker\".",
        "It needs a header row with a Status column of checkboxes. Book, Ch #, Chapter Title and Pages columns are used when they're there. For the countdown, type \"Exam Date\" in a cell and put the date in the cell beside it.",
        "In Attending, open Study › PBL Tracker and click Copy script. Apps Script opens in your browser.",
        "In Apps Script, select everything, paste, then click Deploy › New deployment › Web app. Set Execute as: Me and Who has access: Anyone, then Deploy.",
        "Google asks you to authorize. Choose your account, then Advanced › Go to project (it's your own script) › Allow.",
        "Copy the Web app URL, paste it in Study › PBL Tracker and click Connect.",
        "Add your trackers from the Google Drive suggestions, or paste a sheet's link. Check chapters off from the notch, and they're checked in the sheet.",
    ], note: "Attending never sees your Google password. The script runs in your own Google account, opens only sheets named Tracker or PBL, and only ever flips checkboxes.",
       actions: [.init(title: "Open Apps Script", symbol: "arrow.up.right.square") { open("https://script.google.com/home") }])

    static let canvas = Guide(id: "canvas", title: "Canvas", steps: [
        "Sign in to Canvas in your browser and click Account › Settings.",
        "Under Approved Integrations, click + New Access Token. Name it Attending, leave the expiration empty (or pick the end of the semester) and click Generate Token.",
        "Copy the token. Canvas shows it only once.",
        "In Attending, open Settings › Canvas. Enter your school's Canvas address (the part of the link before /courses, like school.instructure.com) and paste the token, then click Connect.",
        "Announcements and due work appear on Home and in Study, and your Canvas calendar is added to Calendars.",
    ], note: "If your school blocks tokens, you can still get due dates: in Canvas, open Calendar › Calendar Feed, copy the link and add it in Settings › Calendars. To disconnect, click Disconnect here and delete the token in Canvas.")

    static let calendars = Guide(id: "calendars", title: "Calendars (Google, Outlook, school)", steps: [
        "Easiest: add your Google or Microsoft account to the Mac in System Settings › Internet Accounts with Calendars turned on. Attending reads every calendar the Mac has.",
        "Or use a private calendar link. Google Calendar: on the web, open Settings › your calendar › Integrate calendar › Secret address in iCal format.",
        "Outlook: on the web, open Settings › Calendar › Shared calendars › Publish a calendar, choose Can view all details, and copy the ICS link.",
        "Canvas or a school calendar: Canvas › Calendar › Calendar Feed, or the iCal/webcal link your school gives you.",
        "Paste the link in Settings › Calendars › Add a calendar link.",
        "For classes and pre-reads, pick that calendar under Settings › Study › Classes come from. Pre-reads come from event notes like \"Pre-read: chapter 12\".",
    ], note: "Private links work like passwords: anyone with one can see that calendar. Attending keeps them in a file only you can read.",
       actions: [.init(title: "Open Internet Accounts", symbol: "person.crop.circle") { open("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") }])

    static let reminders = Guide(id: "reminders", title: "Apple Reminders", steps: [
        "Turn on Apple Reminders on Home in Settings › Reminders.",
        "macOS asks for Reminders access. Click Allow (full access, so Attending can check items off).",
        "Today's and overdue reminders, plus the next few coming up from every list, show on Home. Click one to complete it, or type in the field to add one for today.",
        "Reminders on your iPhone show up too, through iCloud.",
    ], note: "If you clicked Don't Allow, turn Attending on in System Settings › Privacy & Security › Reminders.",
       actions: [.init(title: "Open Privacy Settings", symbol: "lock") { Onboarding.openPrivacy("Privacy_Reminders") }])

    static let anki = Guide(id: "anki", title: "Anki", steps: [
        "Install Anki from apps.ankiweb.net and open it once so Attending can find your collection.",
        "For deck buttons and live review counts, install AnkiConnect: in Anki, open Tools › Add-ons › Get Add-ons, paste 2055492159 and click OK, then restart Anki.",
        "Due cards, today's reviews and your streak show in Study and on Home. Start a study session with a review goal from Study › Study session.",
    ], actions: [.init(title: "AnkiConnect page", symbol: "arrow.up.right.square") { open("https://ankiweb.net/shared/info/2055492159") }])

    static let blocks = Guide(id: "blocks", title: "Question blocks", steps: [
        "Open Study › Question block, pick 40 in 60m (or set your own) and click Start block.",
        "To have the notch follow UWorld, AMBOSS and similar pages, allow Accessibility (Settings › Volume & brightness › Grant access, or System Settings › Privacy & Security › Accessibility). It reads only the \"Item 12 of 40\" number.",
        "If it can't read the page, ⌃⌘→ moves to the next question and ⌃⌘← goes back, or use the arrows when you hover the notch.",
        "When the block ends, tap the subjects you missed. Weak spots ranks them for the week, and Quiz me asks Gemini about them.",
    ], actions: [.init(title: "Open Accessibility", symbol: "accessibility") { Onboarding.openPrivacy("Privacy_Accessibility") }])

    static let salah = Guide(id: "salah", title: "Prayer times", steps: [
        "Allow Location when asked (or in System Settings › Privacy & Security › Location Services). Only an approximate location is used, and times are calculated on your Mac.",
        "Pick your calculation method in Settings › Salah: ISNA is common in North America; the two Shia methods time Maghrib after the redness and show Islamic midnight.",
        "Choose Standard or Hanafi Asr, and set your masjid's khutbah time for the Jummah reminder.",
        "Tap a prayer on the Salah card to mark it prayed. The notch reminds you at each prayer time and 15 minutes before one ends.",
    ], actions: [.init(title: "Open Location Services", symbol: "location") { Onboarding.openPrivacy("Privacy_LocationServices") }])

    static let agents = Guide(id: "agents", title: "Claude Code and Codex", steps: [
        "Claude Code: click Connect in Settings › Agents. Attending adds its hooks to ~/.claude/settings.json (yours are kept, with a backup). Start a new Claude Code session afterward.",
        "Claude's questions, plan approvals and permission requests then appear as cards in the notch.",
        "Codex: sessions from the ChatGPT and Codex apps show up on their own. For approvals in the notch, click Connect next to Codex approvals; Codex asks you to trust the new hook once (in the CLI, type /hooks).",
        "Claude usage: sign in to Claude in the Ask AI tab, and your 5-hour and weekly limits show on Home.",
    ])

    static let all: [Guide] = [tracker, canvas, calendars, reminders, anki, blocks, salah, agents]
}

/// A guide that opens in place: numbered steps, a note and buttons.
struct GuideView: View {
    let guide: Guide
    /// In Help the guide is listed by name; in its own section it reads "How to set up …".
    var listed = false
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 16, height: 16).background(Circle().fill(Theme.secondary))
                        Text(step).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                if let note = guide.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                if !guide.actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(guide.actions, id: \.title) { action in PillButton(title: action.title, symbol: action.symbol) { action.run() } }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text(listed ? guide.title : "How to set up \(guide.title.components(separatedBy: " (").first ?? guide.title)")
                .font(.system(size: 12, weight: .medium))
        }
    }
}
