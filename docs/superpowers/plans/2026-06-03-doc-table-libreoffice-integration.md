# DOC Table Parsing Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace DOC binary table parsing with LibreOffice's ReadDef() approach while preserving existing data structures and XML generation.

**Architecture:** Extend DocTableCell to hold full cell properties (vMerge, borders, shading), enhance parseTDefTableRowInfo for border/shading extraction, fix table assembly logic to correctly use parsed merge flags, add XML output for new properties.

**Tech Stack:** C++ (ArkTS/NAPI), HarmonyOS, LibreOffice WW8 parsing patterns

---

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `entry/src/main/cpp/office_converter/office_converter.cpp` | Modify | Main changes - extend structures, fix parsing/assembly |
| `entry/src/main/cpp/office_converter/office_converter.cpp.backup` | Create | Safety backup before changes |

---

## Task 1: Backup and Extend DocTableCell Structure

**Files:**
- Modify: `entry/src/main/cpp/office_converter/office_converter.cpp:3160-3163`

- [ ] **Step 1: Create backup of office_converter.cpp**

```bash
cp entry/src/main/cpp/office_converter/office_converter.cpp \
   entry/src/main/cpp/office_converter/office_converter.cpp.backup
```

- [ ] **Step 2: Extend DocTableCell structure with full properties**

Replace lines 3160-3163 with:

```cpp
struct DocTableCell {
    std::string text;
    int colSpan = 1;              // gridSpan for horizontal merged cells
    int rowSpan = 1;              // for vertical merge tracking
    bool vMergeRestart = false;   // first cell of vertical merge range
    bool vMergeContinue = false;  // continuation of vertical merge
    
    // Borders: 4 bytes each [dptLineWidth, brcType, ico, dptSpace]
    uint8_t brcTop[4] = {0, 0, 0, 0};
    uint8_t brcLeft[4] = {0, 0, 0, 0};
    uint8_t brcBottom[4] = {0, 0, 0, 0};
    uint8_t brcRight[4] = {0, 0, 0, 0};
    
    // Shading: fore/back color (5 bits each), style (6 bits)
    uint16_t shdBits = 0;
    
    // Text direction: 0=horizontal, 1=top-to-bottom, 2=bottom-to-top
    uint8_t textDirection = 0;
    
    // Vertical alignment: 0=top, 1=center, 2=bottom
    uint8_t vertAlign = 0;
};
```

- [ ] **Step 3: Commit structure changes**

```bash
git add entry/src/main/cpp/office_converter/office_converter.cpp
git commit -m "feat(doc): extend DocTableCell with vMerge, borders, shading"
```

---

## Task 2: Extend WW8_TCell Structure with Borders and Shading

**Files:**
- Modify: `entry/src/main/cpp/office_converter/office_converter.cpp:2251-2256`

- [ ] **Step 1: Extend WW8_TCell structure to include borders**

Replace lines 2251-2256 with:

```cpp
struct WW8_TCell {
    // Merge flags (from aBits1Ver8)
    uint8_t bFirstMerged;   // bit 0 - first cell of horizontal merge
    uint8_t bMerged;        // bit 1 - merged with preceding cell
    uint8_t bVertMerge;     // bit 5 - vertically merged
    uint8_t bVertRestart;   // bit 6 - first cell of vertical merge
    
    // Additional flags
    uint8_t bVertical;      // bit 2 - vertical text flow
    uint8_t bBackward;      // bit 3 - bottom-to-top for vertical
    uint8_t nVertAlign;     // bits 7-8 (shifted) - 0=top, 1=center, 2=bottom
    
    // Borders (4 bytes each, from rgbrcVer8)
    // Format: [dptLineWidth, brcType, ico, dptSpace+flags]
    uint8_t brcTop[4];
    uint8_t brcLeft[4];
    uint8_t brcBottom[4];
    uint8_t brcRight[4];
    
    // Shading (from sprmTDefTableShd or sprmTDefTableNewShd)
    uint16_t shdBits;       // fore/back/style packed
};
```

- [ ] **Step 2: Commit WW8_TCell extension**

```bash
git add entry/src/main/cpp/office_converter/office_converter.cpp
git commit -m "feat(doc): extend WW8_TCell with borders and shading fields

"
```

---

## Task 3: Update parseTDefTableRowInfo to Extract Borders

**Files:**
- Modify: `entry/src/main/cpp/office_converter/office_converter.cpp:2332-2349`

- [ ] **Step 1: Update TC80 parsing to extract borders and additional flags**

Replace lines 2332-2349 with:

```cpp
    // === Read TC80 array - ww8par2.cxx:1166-1186 (Ver8 parsing) ===
    info.cells.reserve(n);
    for (uint8_t c = 0; c < n; c++) {
        // WW8_TCellVer8 starts at rgTc80Off + c * 20
        // Layout: [0..1]=aBits1Ver8, [2..3]=aUnused, [4..19]=rgbrcVer8[4]
        const uint8_t* pTc80 = &operand[rgTc80Off + c * 20];

        // aBits1Ver8 is SVBT16 at offset 0
        uint16_t aBits1 = SVBT16ToUInt16(pTc80);

        WW8_TCell cell;
        // LibreOffice ww8par2.cxx:1170-1177
        cell.bFirstMerged = (uint8_t)((aBits1 & 0x0001) != 0);
        cell.bMerged      = (uint8_t)((aBits1 & 0x0002) != 0);
        cell.bVertical    = (uint8_t)((aBits1 & 0x0004) != 0);
        cell.bBackward    = (uint8_t)((aBits1 & 0x0008) != 0);
        cell.bVertMerge   = (uint8_t)((aBits1 & 0x0020) != 0);
        cell.bVertRestart = (uint8_t)((aBits1 & 0x0040) != 0);
        cell.nVertAlign   = (uint8_t)((aBits1 & 0x0180) >> 7);  // bits 7-8

        // Extract borders from rgbrcVer8 (ww8struc.hxx:574-580)
        // Each border is 4 bytes: [dptLineWidth, brcType, ico, dptSpace+flags]
        // rgbrcVer8[0] = top (offset 4-7), [1] = left (8-11), [2] = bot (12-15), [3] = right (16-19)
        memcpy(cell.brcTop,    pTc80 + 4,  4);
        memcpy(cell.brcLeft,   pTc80 + 8,  4);
        memcpy(cell.brcBottom, pTc80 + 12, 4);
        memcpy(cell.brcRight,  pTc80 + 16, 4);
        
        cell.shdBits = 0;  // Shading parsed separately via sprmTDefTableShd

        info.cells.push_back(cell);
    }
```

- [ ] **Step 2: Update diagnostic dump to show new fields**

Replace lines 2351-2367 with:

```cpp
    // Diagnostic: dump TC80 flags (LibreOffice format)
    {
        std::string dump;
        for (uint8_t c = 0; c < n && c < 8; c++) {
            char buf[64];
            snprintf(buf, sizeof(buf), "[%u]:FM=%d M=%d VM=%d VR=%d V=%d B=%d VA=%d",
                     (unsigned)c,
                     (int)info.cells[c].bFirstMerged,
                     (int)info.cells[c].bMerged,
                     (int)info.cells[c].bVertMerge,
                     (int)info.cells[c].bVertRestart,
                     (int)info.cells[c].bVertical,
                     (int)info.cells[c].bBackward,
                     (int)info.cells[c].nVertAlign);
            if (!dump.empty()) dump += " ";
            dump += buf;
        }
        OH_LOG_INFO(LOG_APP, "DOC: TC80 LibreOffice parse n=%{public}d: %{public}s",
                    (int)n, dump.c_str());
    }
```

- [ ] **Step 3: Commit parsing updates**

```bash
git add entry/src/main/cpp/office_converter/office_converter.cpp
git commit -m "feat(doc): parse borders and all TC80 flags from TDefTable

"
```

---

## Task 4: Add Shading Parsing from sprmTDefTableShd

**Files:**
- Modify: `entry/src/main/cpp/office_converter/office_converter.cpp:~3400+`

- [ ] **Step 1: Add shading parsing helper function**

Insert after parseTDefTableRowInfo function (around line 2383):

```cpp
/**
 * Parse sprmTDefTableShd / sprmTDefTableNewShd for cell shading
 * LibreOffice WW8_SHD structure (ww8struc.hxx:582-618):
 *   nFore (5 bits)  = bits 0-4 (0x001F) - foreground color
 *   nBack (5 bits)  = bits 5-9 (0x03E0) - background color  
 *   nStyle (6 bits) = bits 10-15 (0x7C00 for Ver8) - fill pattern
 */
static std::vector<uint16_t> parseTDefTableShd(const std::vector<uint8_t>& operand) {
    std::vector<uint16_t> shdBits;
    
    if (operand.size() < 2) return shdBits;
    
    // sprmTDefTableShd operand: nCols (1 byte) + n * 2 bytes (SHD entries)
    uint8_t nCols = operand[0];
    if (nCols == 0 || nCols > 63) return shdBits;
    
    if (operand.size() < 1 + nCols * 2) return shdBits;
    
    for (uint8_t c = 0; c < nCols; c++) {
        uint16_t shd = SVBT16ToUInt16(&operand[1 + c * 2]);
        shdBits.push_back(shd);
    }
    
    return shdBits;
}
```

- [ ] **Step 2: Commit shading parsing helper**

```bash
git add entry/src/main/cpp/office_converter/office_converter.cpp
git commit -m "feat(doc): add parseTDefTableShd helper function

"
```

---

## Task 5: Update Table Assembly to Use bMerged/bFirstMerged Correctly

**Files:**
- Modify: `entry/src/main/cpp/office_converter/office_converter.cpp:3940-3978`

- [ ] **Step 1: Update horizontal merge handling in table assembly**

Replace lines 3943-3972 with:

```cpp
                    std::vector<DocTableCell> row;
                    int cellIdx = 0;
                    for (int k = prevTtp + 1; k < ttpIdx; k++, cellIdx++) {
                        // Use LibreOffice flags directly
                        WW8_TCell* pTc = (rowInfo && cellIdx < (int)rowInfo->cells.size())
                                        ? &rowInfo->cells[cellIdx] : nullptr;
                        
                        // bMerged=1 means this cell is continuation of preceding cell
                        // (LibreOffice WW8_TCell.bMerged, ww8struc.hxx:532)
                        bool isContinuation = false;
                        if (pTc && pTc->bMerged == 1) {
                            isContinuation = true;
                        }
                        
                        // Check horizontal merge ranges from sprmTMerge (fallback)
                        if (!isContinuation && !mergeRanges.empty()) {
                            for (const auto& mr : mergeRanges) {
                                if (cellIdx >= mr.itcFirst && cellIdx < mr.itcLim) {
                                    if (cellIdx > mr.itcFirst) isContinuation = true;
                                    break;
                                }
                            }
                        }

                        if (isContinuation && !row.empty()) {
                            // Merge with preceding cell: increment gridSpan
                            row.back().colSpan += 1;
                            if (!cells[k].text.empty()) {
                                row.back().text += (row.back().text.empty() ? "" : "\n") + cells[k].text;
                            }
                        } else {
                            // New cell (not merged)
                            DocTableCell tc;
                            tc.text = cells[k].text;
                            
                            // Calculate gridSpan from rgdxaCenter
                            tc.colSpan = (cellIdx < (int)cellSpan.size()) ? cellSpan[cellIdx] : 1;
                            
                            // Copy borders and properties from WW8_TCell
                            if (pTc) {
                                memcpy(tc.brcTop, pTc->brcTop, 4);
                                memcpy(tc.brcLeft, pTc->brcLeft, 4);
                                memcpy(tc.brcBottom, pTc->brcBottom, 4);
                                memcpy(tc.brcRight, pTc->brcRight, 4);
                                tc.shdBits = pTc->shdBits;
                                tc.textDirection = pTc->bVertical ? (pTc->bBackward ? 2 : 1) : 0;
                                tc.vertAlign = pTc->nVertAlign;
                                
                                // Vertical merge flags
                                tc.vMergeRestart = (pTc->bVertMerge == 1 && pTc->bVertRestart == 1);
                                tc.vMergeContinue = (pTc->bVertMerge == 1 && pTc->bVertRestart == 0);
                            }
                            
                            row.push_back(tc);
                        }
                    }
```

- [ ] **Step 2: Commit assembly logic fix**

```bash
git add entry/src/main/cpp/office_converter/office_converter.cpp
git commit -m "fix(doc): use LibreOffice bMerged flag for horizontal merge detection

"
```

---

## Task 6: Add XML Output for vMerge

**Files:**
- Modify: `entry/src/main/cpp/office_converter/office_converter.cpp:4479-4483`

- [ ] **Step 1: Add vMerge output in tcPr section**

Replace lines 4479-4483 with:

```cpp
                    // Build tcPr with optional gridSpan and vMerge
                    std::string tcPr = "<w:tcPr>";
                    if (span > 1) {
                        tcPr += "<w:gridSpan w:val=\"" + std::to_string(span) + "\"/>";
                    }
                    // Vertical merge: restart or continue
                    if (row.cells[c].vMergeRestart) {
                        tcPr += "<w:vMerge w:val=\"restart\"/>";
                    } else if (row.cells[c].vMergeContinue) {
                        tcPr += "<w:vMerge w:val=\"continue\"/>";
                    }
                    // Vertical alignment
                    if (row.cells[c].vertAlign > 0) {
                        const char* valign[] = {"top", "center", "bottom"};
                        tcPr += "<w:vAlign w:val=\"" + std::string(valign[row.cells[c].vertAlign]) + "\"/>";
                    }
                    tcPr += "<w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr>";
```

- [ ] **Step 2: Commit vMerge XML output**

```bash
git add entry/src/main/cpp/office_converter/office_converter.cpp
git commit -m "feat(doc): add w:vMerge and w:vAlign XML output

"
```

---

## Task 7: Add XML Output for Borders

**Files:**
- Modify: `entry/src/main/cpp/office_converter/office_converter.cpp:4479-4506`

- [ ] **Step 1: Add border output helper function**

Insert before the XML generation section (around line 4430):

```cpp
/**
 * Convert WW8_BRC border to OOXML w:tcBorders element
 * Border format: [dptLineWidth, brcType, ico, dptSpace+flags]
 * OOXML: w:val (single/double/etc), w:sz (1/8pt * 8 = eighths), w:color (hex or auto)
 */
static std::string borderToXml(const char* side, const uint8_t* brc) {
    if (brc[0] == 0 && brc[1] == 0) return "";  // No border
    
    // brcType: 0=none, 1=single, 2=thick, 3=double, etc.
    const char* types[] = {"none", "single", "thick", "double", 
                           "dotted", "dashed", "nil", "nil", "nil", "nil"};
    const char* type = (brc[1] < 10) ? types[brc[1]] : "single";
    
    // dptLineWidth is in 1/8pt, OOXML w:sz is in 1/8pt (eighths of a point)
    int sz = brc[0] * 8;  // Convert to eighths
    
    // ico is color index (1-17), for simplicity use "auto" or map to hex
    std::string color = "auto";
    if (brc[2] > 0 && brc[2] <= 17) {
        // Basic color mapping (MS-DOC color indices)
        const char* colors[] = {"auto", "000000", "0000FF", "00FF00", "FF0000",
                                "FFFF00", "FF00FF", "00FFFF", "FFFFFF", "auto",
                                "auto", "auto", "auto", "auto", "auto", "auto", "auto", "auto"};
        color = colors[brc[2]];
    }
    
    return std::string("<w:") + side + " w:val=\"" + type + 
           "\" w:sz=\"" + std::to_string(sz) + 
           "\" w:color=\"" + color + "\"/>";
}
```

- [ ] **Step 2: Add border output in tcPr**

Modify the tcPr building section (around line 4479) to add borders:

```cpp
                    // Build tcPr with optional gridSpan, vMerge, borders
                    std::string tcPr = "<w:tcPr>";
                    if (span > 1) {
                        tcPr += "<w:gridSpan w:val=\"" + std::to_string(span) + "\"/>";
                    }
                    if (row.cells[c].vMergeRestart) {
                        tcPr += "<w:vMerge w:val=\"restart\"/>";
                    } else if (row.cells[c].vMergeContinue) {
                        tcPr += "<w:vMerge w:val=\"continue\"/>";
                    }
                    if (row.cells[c].vertAlign > 0) {
                        const char* valign[] = {"top", "center", "bottom"};
                        tcPr += "<w:vAlign w:val=\"" + std::string(valign[row.cells[c].vertAlign]) + "\"/>";
                    }
                    
                    // Cell borders
                    std::string borders;
                    borders += borderToXml("top", row.cells[c].brcTop);
                    borders += borderToXml("left", row.cells[c].brcLeft);
                    borders += borderToXml("bottom", row.cells[c].brcBottom);
                    borders += borderToXml("right", row.cells[c].brcRight);
                    if (!borders.empty()) {
                        tcPr += "<w:tcBorders>" + borders + "</w:tcBorders>";
                    }
                    
                    tcPr += "<w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr>";
```

- [ ] **Step 3: Commit border XML output**

```bash
git add entry/src/main/cpp/office_converter/office_converter.cpp
git commit -m "feat(doc): add w:tcBorders XML output from WW8_BRC data

"
```

---

## Task 8: Add XML Output for Shading

**Files:**
- Modify: `entry/src/main/cpp/office_converter/office_converter.cpp` (after borderToXml)

- [ ] **Step 1: Add shading output helper function**

Insert after borderToXml function:

```cpp
/**
 * Convert WW8_SHD shading to OOXML w:shd element
 * SHD bits: nFore (bits 0-4), nBack (bits 5-9), nStyle (bits 10-15)
 */
static std::string shdToXml(uint16_t shdBits) {
    if (shdBits == 0) return "";
    
    // Extract colors and style
    uint8_t nFore = shdBits & 0x1F;      // bits 0-4
    uint8_t nBack = (shdBits >> 5) & 0x1F;  // bits 5-9
    uint8_t nStyle = (shdBits >> 10) & 0x3F; // bits 10-15
    
    // Basic color index mapping for fill (background)
    const char* colors[] = {"auto", "000000", "0000FF", "00FF00", "FF0000",
                            "FFFF00", "FF00FF", "00FFFF", "FFFFFF", "auto",
                            "auto", "auto", "auto", "auto", "auto", "auto", "auto", "auto"};
    
    std::string fill = (nBack < 18) ? colors[nBack] : "auto";
    
    // Style: 0=clear, 1=solid, etc.
    const char* style = (nStyle == 0) ? "clear" : "solid";
    
    return "<w:shd w:val=\"" + std::string(style) + "\" w:fill=\"" + fill + "\"/>";
}
```

- [ ] **Step 2: Add shading output in tcPr**

Add shading to the tcPr building section:

```cpp
                    // Shading
                    std::string shading = shdToXml(row.cells[c].shdBits);
                    if (!shading.empty()) {
                        tcPr += shading;
                    }
```

- [ ] **Step 3: Commit shading XML output**

```bash
git add entry/src/main/cpp/office_converter/office_converter.cpp
git commit -m "feat(doc): add w:shd XML output from WW8_SHD data

"
```

---

## Task 9: Add Text Direction Output

**Files:**
- Modify: `entry/src/main/cpp/office_converter/office_converter.cpp` (in tcPr section)

- [ ] **Step 1: Add text direction output in tcPr**

Add textDirection to the tcPr building section:

```cpp
                    // Text direction for vertical cells
                    if (row.cells[c].textDirection > 0) {
                        const char* dirs[] = {"lrTb", "tbRl", "btLr"};
                        tcPr += "<w:textDirection w:val=\"" + std::string(dirs[row.cells[c].textDirection]) + "\"/>";
                    }
```

- [ ] **Step 2: Commit text direction output**

```bash
git add entry/src/main/cpp/office_converter/office_converter.cpp
git commit -m "feat(doc): add w:textDirection XML output for vertical cells

"
```

---

## Task 10: Test and Verify

**Files:**
- Test: Use existing DOC files with tables

- [ ] **Step 1: Build the project**

```bash
cd entry && hvigorw assembleHap --no-daemon
```

- [ ] **Step 2: Test with a simple DOC file containing a table**

Run the application and convert a DOC file with a 2x2 table.

- [ ] **Step 3: Verify output DOCX structure**

Unzip the output DOCX and check word/document.xml for:
- `<w:gridSpan>` values on merged cells
- `<w:vMerge>` for vertically merged cells
- `<w:tcBorders>` for cells with borders
- `<w:shd>` for cells with shading

- [ ] **Step 4: Test complex table with merged cells**

Test with a DOC file containing:
- Horizontal merged cells
- Vertical merged cells
- Cells with borders
- Cells with background colors

- [ ] **Step 5: Verify no regression in non-table content**

Ensure paragraphs, images, and other content still work correctly.

---

## Task 11: Final Commit and Cleanup

- [ ] **Step 1: Create final commit**

```bash
git add -A
git commit -m "feat(doc): complete LibreOffice-style table parsing integration

- Extended DocTableCell with vMerge, borders, shading, textDirection
- Updated WW8_TCell with full border and shading fields
- Fixed horizontal merge detection using bMerged flag
- Added XML output for w:vMerge, w:tcBorders, w:shd, w:textDirection
- Preserved existing structures and DOCX packaging

"
```

- [ ] **Step 2: Remove backup file if everything works**

```bash
rm entry/src/main/cpp/office_converter/office_converter.cpp.backup
```

---

## Success Criteria Verification

After completing all tasks, verify:

- [ ] TDefTable parsing extracts rgdxaCenter boundaries correctly
- [ ] Horizontal merges (gridSpan) use bMerged/bFirstMerged flags
- [ ] Vertical merges (vMerge) use bVertMerge/bVertRestart flags  
- [ ] Borders (w:tcBorders) output from WW8_BRC data
- [ ] Shading (w:shd) output from WW8_SHD data
- [ ] Column widths accurate from rgdxaCenter differences
- [ ] No regression in paragraph/image handling
- [ ] PPT/XLS code unchanged