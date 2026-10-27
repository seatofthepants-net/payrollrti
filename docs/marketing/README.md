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
| `not-installed-light.png`, `not-installed-dark.png` | 2880×1800 | PayrollRTI's "Basic PAYE Tools isn't installed" screen with the GOV.UK download button. |

**Dark mode:** PayrollRTI's own window chrome and screens follow the system appearance, but Basic PAYE Tools' pages
are HMRC's HTML and always light. In the dark variants of BPT screens only the title bar changes.

**Not included:** the menu-bar menu (🟢/🔴) and the Settings window. The capture method can't render menus or
SwiftUI forms, so take those by hand: open the menu or window, press ⌘⇧4 then Space, and click it.

**Regenerating:** run `scripts/marketing-shots.sh`. It builds the Debug app, captures PayrollRTI's own window only
(never the desktop or other apps), and refuses to run if Basic PAYE Tools has any employers set up.

Basic PAYE Tools and its pages are © Crown copyright, HM Revenue & Customs.
