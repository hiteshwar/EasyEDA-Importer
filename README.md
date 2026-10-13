# EasyEDA Importer for Altium Designer

> AI-assisted. Verify specifics before official use.


<img width="597" height="684" alt="image" src="https://github.com/user-attachments/assets/13f023c4-9b45-4593-967b-b812ea811fd5" />


**Get a ready-to-use Altium part from an LCSC / JLCPCB number in seconds.** Type a number such as `C2040` and the importer:

- downloads the part from EasyEDA (the free CAD library behind LCSC and JLCPCB);
- adds the **schematic symbol**, the **PCB footprint** and the **3D STEP model** to an Altium library of your choice;
- links the footprint to the symbol;
- renames the part's parameters to your team's naming convention;
- places the part on your open schematic sheet.

It's a plain Altium script: there's nothing to compile, no Altium extension to install and no admin rights needed.

| | |
|---|---|
| Tested with | Altium Designer 26.10.1 on Windows 11 (also inside a Parallels VM on a Mac) |
| Needs | Windows PowerShell 5.1, which comes with Windows 10/11, and internet access to `easyeda.com` |
| Owner | Hitesh |

---

## Contents

1. [Quick start](#1-quick-start)
2. [Installation](#2-installation)
3. [Importing parts](#3-importing-parts)
4. [Choosing the libraries](#4-choosing-the-libraries)
5. [Parameter names](#5-parameter-names)
6. [Placing parts on the schematic](#6-placing-parts-on-the-schematic)
7. [What gets created](#7-what-gets-created)
8. [Advanced settings](#8-advanced-settings)
9. [Troubleshooting](#9-troubleshooting)
10. [Known limitations](#10-known-limitations)
11. [How it works and the files in this folder](#11-how-it-works-and-the-files-in-this-folder)

---

## 1. Quick start

1. Copy the `EasyEDA-Importer` folder to your Windows PC, e.g. `C:\Users\<you>\Documents\EasyEDA-Importer`.
2. Double-click `Test-Helper.cmd`. It should report `6 of 6 tests passed`.
3. In Altium, go to **File » Open…** and open `EasyEDA_Importer.PrjScr`.
4. Open the schematic sheet you're working on, then go to **File » Run Script…** and choose **EasyEDA_Importer.pas » ImportEasyEDAPart**.
5. Type an LCSC number (e.g. `C2040`) and click **Import**.

## 2. Installation

### 2.1 Copy the folder

- Copy the whole `EasyEDA-Importer` folder to a **local Windows drive**. A good place is `C:\Users\<you>\Documents\EasyEDA-Importer`.
- Keep all the files together. The script looks for its helper files next to itself.
- **Parallels / VM users:** don't run it from the Mac shared folder (`\\Mac\Home\…`). Windows treats that as a network location, which can stop PowerShell scripts from running and makes everything slower.
- If you received the folder as a `.zip`, first right-click the zip, choose **Properties**, tick **Unblock**, and then extract it.

### 2.2 Check the download helper (one minute)

Double-click **`Test-Helper.cmd`**. It does two things:

1. It runs the built-in self-test, which should report `6 of 6 tests passed`.
2. It asks for an LCSC number. Enter e.g. `C2040` to try a real download. It should end with `OK C2040 -> …\Libraries\cache\C2040.part.txt`.

If the download fails with a network error, open https://easyeda.com in a browser **on the same PC or VM**. If the browser can't reach it either, check the VPN, proxy or VM network settings.

### 2.3 Open the script in Altium

**File » Open…** → `EasyEDA_Importer.PrjScr`. The script project now appears in the *Projects* panel.

### 2.4 Optional: always available + menu button

- **Always available:** go to **Preferences » Scripting System » Global Projects**, click **Install…** and pick `EasyEDA_Importer.PrjScr`. The script then appears under **File » Run Script…** without opening the project first.
- **Menu or toolbar button:** right-click the menu bar, choose **Customize…**, and add a new command:
  - **Process:** `ScriptingSystem:RunScript`
  - **Parameters:** `ProjectName=C:\Users\<you>\Documents\EasyEDA-Importer\EasyEDA_Importer.PrjScr|ProcName=EasyEDA_Importer.pas>ImportEasyEDAPart`
  - **Caption:** `EasyEDA Import`

  Then drag the new command onto a menu or toolbar.

## 3. Importing parts

1. *(Optional)* Open the schematic sheet where the parts should go and click its tab so it's the active document.
2. Go to **File » Run Script…** and choose **EasyEDA_Importer.pas » ImportEasyEDAPart**. The import dialog opens:

   | Section | What it's for |
   |---|---|
   | **Parts** | One or more LCSC / JLCPCB numbers, separated by commas, e.g. `C2040, C46749, C56742`. You'll find these on [jlcpcb.com/parts](https://jlcpcb.com/parts) or [lcsc.com](https://www.lcsc.com): it's the code that starts with **C**. |
   | **Target libraries** | Where the parts are stored. See [section 4](#4-choosing-the-libraries). |
   | **Symbol parameters** | How the parameters are named. See [section 5](#5-parameter-names). |
   | **Placement** | Whether, and how far apart, the parts are placed on the sheet. See [section 6](#6-placing-parts-on-the-schematic). |
   | **Remember these settings** | Saves everything except the part numbers for next time. |

3. Click **Import**. Each part takes a few seconds, and a minimised PowerShell window appears briefly while it downloads. Altium can look frozen during this time; that's normal.
4. A summary appears. It lists the libraries used, each part's symbol and footprint (with its pad count), any warnings, and where each part was placed.

**Re-importing a part** replaces its symbol. A footprint whose name is already in the library is reused rather than replaced, because footprints are often shared, e.g. `C0603`. See [section 8](#8-advanced-settings) to change this.

## 4. Choosing the libraries

| What you enter | What happens |
|---|---|
| Both boxes empty (default) | Parts go to `EasyEDA.SchLib` and `EasyEDA.PcbLib` in the `Libraries` folder next to the script. |
| **Browse…** to an existing `.SchLib` | Parts are added to that library. If a `.PcbLib` with the same name exists in the same folder, it's filled in automatically. |
| **Browse…** to an existing `.PcbLib` | Footprints go to that library. |
| A plain name, e.g. `MyParts` | `MyParts.SchLib` / `MyParts.PcbLib` are created in, or reused from, the `Libraries` folder. |
| A full path, e.g. `D:\Libs\Connectors.SchLib` | That file is used, and created if it doesn't exist. |
| Only the schematic library filled in | The PCB library gets the same name, in the same folder. |

**Use EasyEDA default** clears both boxes. The libraries are saved and installed automatically, so the parts show up in the **Components** panel straight away.

Tip: libraries that are part of your team's version-controlled library repository can be picked with **Browse…**, but remember to commit them afterwards.

## 5. Parameter names

EasyEDA doesn't name parameters consistently. The same value can arrive as `Manufacturer Part`, `ManufacturerPart` or `Manufacturer Part Number`. The **Symbol parameters** list maps all of these to the names your team uses, so **every imported part ends up with the same parameter set**.

### 5.1 Format

One line per parameter:

```
New name = EasyEDA name, other EasyEDA name, ...
```

- When matching, **upper/lower case, spaces, `_` and `-` are ignored**. So `ManufacturerPart`, `Manufacturer Part`, `manufacturer_part` and `MANUFACTURER-PART` are all treated as the same name.
- The new name itself always counts as a match.
- Lines starting with `#` are notes.
- If two EasyEDA parameters map to the same new name, the first one wins, so a part never gets duplicate parameters.

### 5.2 Default list

```
Manufacturer = Manufacturer, Mfr, BOM_Manufacturer
Manufacturer Part Number = Manufacturer Part, ManufacturerPart, Manufacturer Part Number, MPN, Mfr Part, BOM_Manufacturer Part
JLCPCB Part Number = Supplier Part, Supplier Part Number, LCSC Part, LCSC Part Number, JLCPCB Part, BOM_Supplier Part
Supplier = Supplier, BOM_Supplier
JLCPCB Part Class = JLCPCB Part Class
Package = Package
Datasheet = Datasheet
Value = Value
```

### 5.3 Common changes

| You want… | Do this |
|---|---|
| A different name, e.g. `MPN` instead of `Manufacturer Part Number` | Change the text before `=`: `MPN = Manufacturer Part, ManufacturerPart, Manufacturer Part Number` |
| An extra EasyEDA parameter | Add a line, e.g. `Tolerance = Tolerance` |
| Everything EasyEDA provides | Untick **Only keep parameters that are in this list**. Unlisted parameters are then imported under their EasyEDA names. |
| To start over | Click **Restore defaults**. |

All parameters are added to the symbol **hidden**. Show the ones you need in Altium as usual.

## 6. Placing parts on the schematic

With **Place parts on the open schematic sheet** ticked, every part from the batch is placed on the sheet, and so is **every unit of a multi-unit part** (e.g. the five units of an FT4232HL).

- **Which sheet:** the sheet that was active when you started the script. If none was, the script uses the first schematic sheet in the current project.
- **Where:** in a grid starting at (1000, 1000) mil.
  - **Spacing** sets the distance between parts in mil (default 1500).
  - **Per row** sets how many parts go side by side before a new row starts (default 6).
- Then move the parts where you need them and **annotate**. The units of a multi-unit part are recognised as one package, e.g. `U4A … U4E`.

The summary lists every placed part, with its position.

## 7. What gets created

Everything goes into the `Libraries` folder next to the script, unless you chose other libraries:

```
EasyEDA-Importer\
└─ Libraries\
   ├─ EasyEDA.SchLib          symbols   (default library)
   ├─ EasyEDA.PcbLib          footprints with embedded 3D bodies (default library)
   ├─ 3D\<uuid>.step          downloaded STEP models (kept so re-imports are faster)
   └─ cache\                  last download per part (.json, .part.txt, .status.txt) and ee_fetch.log
```

Your dialog choices are saved in `EasyEDA_Importer.settings.txt`, next to the script.

**Each symbol** gets:
- the pins, with their names, numbers and electrical types;
- the body graphics, snapped to Altium's 100 mil grid;
- the designator prefix (`U?`, `R?`, …);
- the part name as its comment;
- a description;
- your mapped parameters;
- a link to its footprint.

**Each footprint** gets:
- **pads**: SMD and through-hole, including slotted holes;
- **holes and vias**: mounting holes and vias;
- **drawings**: silkscreen lines, arcs and filled shapes, plus assembly and mechanical layer drawings;
- **3D model**: the STEP body, positioned from EasyEDA's data.

## 8. Advanced settings

The dialog covers everyday use. These constants at the top of `EasyEDA_Importer.pas` handle less common needs. Open the file in Altium or any text editor to change them:

| Constant | Default | Meaning |
|---|---|---|
| `cLibFolder` | `''` | Folder for the default libraries, the 3D models and the cache. Empty means the `Libraries` folder next to the script. |
| `cReplaceSymbols` | `True` | Re-importing a part replaces its symbol. |
| `cReplaceFootprints` | `False` | `False` reuses an existing footprint with the same name; `True` re-creates it. |
| `cFillBodyRect` | `True` | Gives symbol body rectangles the usual Altium yellow fill. |
| `cUsePython` | `False` | Uses `ee_convert.py` (needs Python 3 on PATH) instead of PowerShell, for PCs where PowerShell scripts are blocked. |

## 9. Troubleshooting

| Symptom | Fix |
|---|---|
| "ee_fetch.ps1 was not found" | Open `EasyEDA_Importer.PrjScr`, not just the `.pas` file, and keep every file of the folder together. |
| "Helper did not produce a result" | Run the command shown in the message in a Command Prompt to see the real error. Also check `Libraries\cache\ee_fetch.log`. |
| "Network error talking to EasyEDA" | Open https://easyeda.com in a browser on the same PC or VM. If that fails too, check the VPN, proxy or VM network settings. |
| "running scripts is disabled" / blocked by policy | The script already uses `-ExecutionPolicy Bypass`. If IT enforces *AllSigned*, set `cUsePython = True` and install Python 3, or ask IT to allow the script. |
| "EasyEDA has no symbol/footprint for …" | Check the number on jlcpcb.com/parts. Not every LCSC part has EasyEDA CAD data. |
| Footprint shows **0 pads** | That footprint name already existed (e.g. an empty one from an earlier failed run), so it was reused. Delete it from the PcbLib and import again, or set `cReplaceFootprints = True`. |
| "Could not create …SchLib" | Create the library once by hand (**File » New » Library**), save it under that name, then run the importer again. |
| "Not placed: no open schematic sheet found" | Open a `.SchDoc` and click its tab before running the script, or drag the part in from the **Components** panel. |
| A script error with a line number | Send the line number and message to the owner (see the top of this file). |

## 10. Known limitations

- **Custom pad shapes:** a polygon-shaped pad becomes a rectangular pad the size of the polygon's outer edges, and the summary warns you when this happens. Check those pads against the datasheet.
- **Footprint text:** EasyEDA's text placeholders on the footprint aren't imported. Altium adds its own designator and comment.
- **3D models:** most models sit correctly. If one is slightly rotated or at the wrong height, adjust it in the 3D body properties.
- **EasyEDA's download API:** it's public but not officially documented, and EasyEDA could change it. If every import suddenly fails, that's the most likely cause; tell the owner.
- **Data quality:** the CAD data comes from EasyEDA's community library. As with any downloaded part, **check the footprint and pinout against the datasheet** before releasing a design.

## 11. How it works and the files in this folder

```
Altium: EasyEDA_Importer.pas  (dialog: EasyEDA_Importer.dfm)
  └─ runs: powershell -ExecutionPolicy Bypass -File ee_fetch.ps1 -Lcsc C2040 -OutDir ...\Libraries
        ├─ GET https://easyeda.com/api/products/C2040/components            symbol + footprint data
        ├─ GET https://modules.easyeda.com/qAxj6KHrDKw4blvCG8QJPs7Y/<uuid>  STEP model
        ├─ GET https://modules.easyeda.com/3dmodel/<uuid>                  mesh (only to find the model's centre and height)
        └─ writes Libraries\cache\C2040.part.txt (simple, integer-only text format)
  └─ reads C2040.part.txt and creates the footprint, 3D body, symbol and parameters, then places the parts
```

| File | Purpose |
|---|---|
| `EasyEDA_Importer.PrjScr` | Altium script project. Open this one. |
| `EasyEDA_Importer.pas` | The Altium script (DelphiScript): the dialog logic, library building and placement. |
| `EasyEDA_Importer.dfm` | Layout of the import dialog. |
| `ee_fetch.ps1` | Download and conversion helper (Windows PowerShell 5.1). |
| `ee_convert.py` | The same helper in Python 3. It's the reference implementation the tests come from, and it's used when `cUsePython = True`. |
| `Test-Helper.cmd` | Double-click to self-test the helper and try a download. |
| `tests\` | Saved EasyEDA responses (`*.raweasy.json`) and the expected converted output (`*.expected.txt`), used by `ee_fetch.ps1 -SelfTest`. |
| `.gitignore` | Keeps the personal `Libraries\` folder and the settings file out of version control. |

### For maintainers

- **Converter changes:** make them in `ee_convert.py` first, then port them line by line to `ee_fetch.ps1`. Regenerate the expected files with `python ee_convert.py tests\<name>.raweasy.json > tests\<name>.expected.txt`, and confirm `powershell -File ee_fetch.ps1 -SelfTest` passes.
- **Part file format** (one record per line, tab-separated): all lengths are integer 1/100 mil, angles are millidegrees, and Y points up. The records are:
  - `META` and `PARAM`: part information and parameters;
  - `SPART`: starts the next unit of a multi-unit symbol;
  - `SPIN`, `SRECT`, `SELLIPSE`, `SARC`, `SPOLY`, `STEXT`: symbol pins and graphics;
  - `FPAD`, `FTRACK`, `FARC`, `FHOLE`, `FVIA`, `FREGION`: footprint primitives;
  - `F3D`: the 3D model;
  - `WARN`: a warning shown in the summary.
- **Things Altium 26's script engine doesn't accept** (found during development):
  - `InputQuery` and `CreateOleObject` don't work; use `ShowMessage` and the `.dfm` form. (`MessageDlg` was also avoided as a precaution; it hasn't been tested.)
  - Assignments that mix a constant with `or` / `and` don't work; use plain `if … then … else`.
  - Library placement via `IntegratedLibraryManager.PlaceLibraryComponent` fails; the script copies the symbol from the library instead.

### Credits

- The original idea and the EasyEDA endpoints come from [expired6978/EasyEDALoader](https://github.com/expired6978/EasyEDALoader) (a C# extension for Altium 24) and [uPesy/easyeda2kicad.py](https://github.com/uPesy/easyeda2kicad.py).
- The test fixtures are raw EasyEDA API responses taken from the test assets of the `easyeda-converter` npm package. `synthetic-shapes` and `multi-unit` are hand-made variants of those.
