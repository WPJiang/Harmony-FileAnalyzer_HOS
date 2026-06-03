# DOC Table Parsing Refactor - LibreOffice Integration Design

## Summary

Replace the DOC binary table parsing logic in `office_converter.cpp` with LibreOffice's accurate `ReadDef()` approach, while preserving existing data structures and XML generation.

## Problem Statement

The current DOC table extraction code in `office_converter.cpp` has multiple errors in:
- Column width detection from TDefTable binary data
- Horizontal cell merge (gridSpan) calculation
- Vertical cell merge handling
- Border and shading property extraction

LibreOffice's `WW8TabBandDesc::ReadDef()` in `ww8par2.cxx` provides proven, accurate parsing of these structures.

## Scope

**In Scope:**
- DOC (Word 97-2003 binary format) table parsing only
- TDefTable sprm parsing
- Cell merge detection (horizontal and vertical)
- Column boundaries from rgdxaCenter
- Border and shading properties
- Text direction for vertical cells

**Out of Scope:**
- PPT and XLS code (no modifications)
- DOCX generation packaging (keep existing)
- Non-table DOC content (paragraphs, images)

## Architecture

### Components Preserved

| Component | Location | Status |
|-----------|----------|--------|
| `DocTableCell` struct | lines 3160-3163 | Keep |
| `DocTableRow` struct | lines 3165-3167 | Keep |
| `DocTable` struct | lines 3169-3171 | Keep |
| `DocContentElement` struct | lines 3173-3178 | Keep |
| XML generation | lines 4438-4510 | Keep (minor additions) |
| DOCX packaging | lines 4554+ | Keep |

### Components Replaced

| Component | Location | Replacement Source |
|-----------|----------|-------------------|
| TDefTable parsing | lines 3319-3600+ | LibreOffice `WW8TabBandDesc::ReadDef()` |
| TTP row grouping | lines 3800-4000 | New assembly logic |
| Merge detection | scattered | LibreOffice `WW8_TCell` flags |

### New Structures (from LibreOffice)

#### WW8_TCell (adapted from ww8struc.hxx:526-555)

```cpp
struct WW8_TCell {
    // Horizontal merge flags
    uint8_t bFirstMerged : 1;  // 0x01 - first cell of merge range
    uint8_t bMerged : 1;       // 0x02 - merged with preceding cell
    // Vertical merge flags
    uint8_t bVertical : 1;     // vertical text flow
    uint8_t bBackward : 1;     // bottom-to-top for vertical
    uint8_t bRotateFont : 1;   // uses @font
    uint8_t bVertMerge : 1;    // vertically merged
    uint8_t bVertRestart : 1;  // first of vertical merge range
    uint8_t nVertAlign : 2;    // 0=top, 1=center, 2=bottom
    
    // Borders (adapted for simpler representation)
    uint8_t brcTop[4];     // dptLineWidth, brcType, ico, dptSpace
    uint8_t brcLeft[4];
    uint8_t brcBottom[4];
    uint8_t brcRight[4];
    
    // Shading
    uint16_t shdBits;      // fore/back color, style
};
```

#### WW8_TabBandDesc (adapted from ww8par2.cxx)

```cpp
struct WW8_TabBandDesc {
    int nWwCols;                    // number of cells in this band
    std::vector<int16_t> nCenter;   // rgdxaCenter - cell boundaries (twips)
    std::vector<WW8_TCell> pTCs;    // cell properties
    
    // Row properties
    int16_t nLineHeight;            // row height
    bool bCantSplit;                // row can't split across pages
    
    void ReadDef(bool bVer67, const uint8_t* pData, short nLen);
};
```

## Implementation Details

### 1. Column Width from rgdxaCenter

LibreOffice reads `(nCols+1)` int16 values representing X-positions:
- `nCenter[0]` = left edge of first cell (usually 0)
- `nCenter[i]` to `nCenter[i+1]` = width of cell i in twips
- For OOXML: convert twips to DXA (same unit), use for `w:tcW`

```cpp
// From ReadDef (ww8par2.cxx:1096-1098)
for (int i = 0; i <= nCols; i++, pT+=2)
    nCenter[i] = SVBT16ToInt16(pT); // X-borders

// Cell width calculation
int cellWidth = nCenter[i+1] - nCenter[i];
```

### 2. Horizontal Merge Detection

LibreOffice's approach (ww8par2.cxx:1141-1162, 1170-1171):
- `bFirstMerged=1` → cell starts a horizontal merge range
- `bMerged=1` → cell is continuation (merged with preceding cell)

In output:
- Skip continuation cells in row cell list
- Add their width to the preceding cell's `gridSpan`

```cpp
// Ver6/7 parsing
uint8_t aBits1 = pTc->aBits1Ver6;
pCurrentTC->bFirstMerged = (aBits1 & 0x01) != 0;
pCurrentTC->bMerged = (aBits1 & 0x02) != 0;

// Ver8 parsing
uint16_t aBits1 = SVBT16ToUInt16(pTc->aBits1Ver8);
pCurrentTC->bFirstMerged = (aBits1 & 0x0001) != 0;
pCurrentTC->bMerged = (aBits1 & 0x0002) != 0;
```

### 3. Vertical Merge Detection

From ww8struc.hxx:536-537:
- `bVertMerge=1` + `bVertRestart=1` → first cell of vertical merge (w:vMerge w:val="restart")
- `bVertMerge=1` + `bVertRestart=0` → continuation cell (w:vMerge w:val="continue")

OOXML output:
```xml
<w:tcPr>
  <w:vMerge w:val="restart"/>  <!-- or "continue" -->
</w:tcPr>
```

### 4. Border Parsing

LibreOffice uses different border structures per version:
- Ver6/7: `WW8_BRCVer6` (2 bytes per border)
- Ver8: `WW8_BRC` (4 bytes per border)
- Ver9+: `WW8_BRCVer9` (8 bytes per border)

For simplicity, extract key fields:
- `dptLineWidth` - line width in 1/8pt
- `brcType` - 0=none, 1=single, 2=thick, 3=double
- `ico` - color index (1-17, or RGB for Ver9)

OOXML output:
```xml
<w:tcBorders>
  <w:top w:val="single" w:sz="8" w:color="auto"/>
</w:tcBorders>
```

### 5. Shading Parsing

From `sprmTDefTableShd` (Ver6/7) and `sprmTDefTableNewShd` (Ver8+):
- `nFore` (5 bits) - foreground color index
- `nBack` (5 bits) - background color index
- `nStyle` (5/6 bits) - fill pattern

OOXML output:
```xml
<w:shd w:fill="FFFF00" w:val="clear"/>
```

### 6. Text Direction

From `bVertical`, `bBackward` flags:
- `bVertical=0` → horizontal text
- `bVertical=1` + `bBackward=0` → top-to-bottom vertical
- `bVertical=1` + `bBackward=1` → bottom-to-top vertical

OOXML output:
```xml
<w:textDirection w:val="tbRl"/>  <!-- or "btLr" -->
```

## Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    DOC Binary File                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │ WordDocument │  │ 0Table/1Table│  │ FIB (header)         │   │
│  │ (text stream)│  │ (TDefTable)  │  │ fcPlcfBtePapx etc    │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            NEW: WW8_TabBandDesc::ReadDef()                       │
│  - Parse sprmTDefTable from PAPX/Prc                            │
│  - Read nCols, rgdxaCenter boundaries                           │
│  - Read WW8_TCell array (merge flags, borders, shading)         │
│  - Handle Ver6/7 vs Ver8+ format differences                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            UPDATED: Table Assembly Logic                         │
│  - Map nCenter[] → column widths                                │
│  - Handle bMerged → gridSpan calculation                         │
│  - Handle bVertMerge → vMerge flags                             │
│  - Convert borders/shading to DocTableCell properties           │
│  - Output: DocTable with accurate rows/cells                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            PRESERVED: XML Generation                             │
│  - String concatenation for w:tbl/w:tr/w:tc                     │
│  - Minor additions: w:vMerge, w:tcBorders, w:shd                │
│  - Output: document.xml content                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│            PRESERVED: DOCX Packaging                             │
│  - ZIP creation with [Content_Types], _rels, word/              │
│  - Final .docx output file                                      │
└─────────────────────────────────────────────────────────────────┘
```

## File Modifications

### Backup

```bash
cp entry/src/main/cpp/office_converter/office_converter.cpp \
   entry/src/main/cpp/office_converter/office_converter.cpp.backup
```

### Changes to office_converter.cpp

| Line Range | Change Type | Description |
|------------|-------------|-------------|
| ~3190 | Add | `WW8_TCell` structure definition |
| ~3200 | Add | `WW8_TabBandDesc` structure with `ReadDef()` method |
| 3319-3600 | Replace | Remove old TDefTable parsing, use `WW8_TabBandDesc::ReadDef()` |
| 3800-4000 | Replace | New assembly logic using LibreOffice merge flags |
| 4438-4510 | Minor Add | Add `w:vMerge`, `w:tcBorders`, `w:shd` output |

### No Changes

- `office_converter.h` (header file)
- PPT conversion code (lines 4568+)
- XLS conversion code
- Image handling
- Paragraph processing

## Testing

### Test Files

Use existing test files in project:
- Simple tables (2x2, 3x3)
- Complex tables with merged cells
- Nested tables
- Tables with borders and shading

### Verification

1. Compare output DOCX with LibreOffice's DOCX export
2. Check gridSpan values for horizontal merges
3. Check vMerge values for vertical merges
4. Verify column widths match source document
5. Check border rendering in Word/LibreOffice

## Success Criteria

- [ ] TDefTable parsing matches LibreOffice's output
- [ ] Horizontal merges (gridSpan) correctly detected
- [ ] Vertical merges (vMerge) correctly detected
- [ ] Column widths accurate within ±1 twip
- [ ] Borders and shading preserved
- [ ] No regression in non-table content
- [ ] PPT/XLS code unchanged and functional