# Marketing screenshots

PayrollRTI running HMRC's Basic PAYE Tools 26.1 (26.1.26134.173934) on macOS 26, captured at 2x from a
1440×900pt window. Basic PAYE Tools was a fresh install with no employers set up, so these contain no payroll or
personal data.

| File | Size (px) | What it shows |
|---|---|---|
| `hero-light.png`, `hero-dark.png` | 3072×1992 | Hero image: BPT home page in the PayrollRTI window, with macOS rounded corners and a soft shadow on a transparent background. |
| `hero-light-flat.png`, `hero-dark-flat.png` | 2880×1800 | The same window, square-cornered with no shadow, for your own treatment. |
| `add-employer-light.png`, `add-employer-dark.png` | 2880×1800 | BPT's "Add employer" form (empty). |
| `calculators-light.png`, `calculators-dark.png` | 2880×1800 | BPT's calculators page. |
| `starting-light.png`, `starting-dark.png` | 2880×1800 | PayrollRTI starting BPT (progress screen). |
| `bpt-not-installed-light.png`, `bpt-not-installed-dark.png` | 2880×1800 | PayrollRTI's "Basic PAYE Tools isn't installed" screen, with the "Download from GOV.UK" button that opens HMRC's download page. Captured with a debug switch that pretends BPT is missing; the real install wasn't touched. |

**Dark mode:** PayrollRTI's own window chrome and screens follow the system appearance, but Basic PAYE Tools' pages
are HMRC's HTML and always light. In the dark variants of BPT screens only the title bar changes.

**Still to capture by hand:** the menu bar (🟢 running, with the menu open showing Start, Stop and Open in Safari)
and PayrollRTI Settings. The scripted capture renders the app's window from inside the app, and that
can't render menus or SwiftUI forms. To take them:

1. Open PayrollRTI and wait for the 🟢 icon.
2. **Menu bar:** click 🟢 to open the menu, press ⌘⇧4, then drag a box around the icon and the open menu. (Space-click
   captures only the menu, without the icon.)
3. **Settings:** press ⌘, in PayrollRTI, press ⌘⇧4 then Space, and click the Settings window.
4. To get the light and dark versions, switch System Settings → Appearance between shots.

macOS saves them to the Desktop at 2x. Rename them to `menubar-light.png`, `menubar-dark.png`, `settings-light.png`
and `settings-dark.png`, and add them here.

**Regenerating:** run `scripts/marketing-shots.sh`. It builds the Debug app, captures PayrollRTI's own window only
(never the desktop or other apps), and refuses to run if Basic PAYE Tools has any employers set up.

Basic PAYE Tools and its pages are © Crown copyright, HM Revenue & Customs.
