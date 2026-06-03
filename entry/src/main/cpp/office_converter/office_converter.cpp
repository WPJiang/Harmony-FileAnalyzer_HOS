/**
 * Office Converter Implementation
 * Converts .xls/.doc/.ppt to .xlsx/.docx/.pptx
 */

#include "office_converter.h"
#include <cstring>
#include <cstdio>
#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <hilog/log.h>
#include <zlib.h>

// Define logging domain and tag for this module
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x03E00
#define LOG_TAG "OfficeConverter"

// OLE2 signature: D0 CF 11 E0 A1 B1 1A E1
static const uint8_t OLE2_SIGNATURE[] = {0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1};

// BIFF record types for XLS
enum BIFFRecord {
    BIFF_BOF = 0x0809,
    BIFF_EOF = 0x000A,
    BIFF_DIMENSIONS = 0x0200,
    BIFF_ROW = 0x0208,
    BIFF_CELL = 0x00FD,  // RK number
    BIFF_LABELSST = 0x00FD,
    BIFF_NUMBER = 0x0203,
    BIFF_LABEL = 0x0204,
    BIFF_SST = 0x00FC,
    BIFF_BOUNDSHEET = 0x0085,
    BIFF_INDEX = 0x020B,
    BIFF_XF = 0x00E0,
    BIFF_FORMAT = 0x041E,
};

OfficeConverter::OfficeConverter() {}

OfficeConverter::~OfficeConverter() {}

bool OfficeConverter::canConvert(const std::string& filePath) {
    std::string ext = filePath.substr(filePath.find_last_of('.'));
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    return (ext == ".xls" || ext == ".doc" || ext == ".ppt");
}

std::string OfficeConverter::getFormatType(const std::string& filePath) {
    std::string ext = filePath.substr(filePath.find_last_of('.'));
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    if (ext == ".xls") return "xls";
    if (ext == ".doc") return "doc";
    if (ext == ".ppt") return "ppt";
    return "";
}

ConversionResult OfficeConverter::convert(const std::string& inputPath, const std::string& outputPath) {
    ConversionResult result;
    result.success = false;
    result.inputPath = inputPath;
    result.outputPath = outputPath;
    result.pageCount = 0;
    result.sheetCount = 0;

    std::string formatType = getFormatType(inputPath);
    result.formatType = formatType;

    if (formatType == "xls") {
        convertXLS(inputPath, outputPath, result);
    } else if (formatType == "doc") {
        convertDOC(inputPath, outputPath, result);
    } else if (formatType == "ppt") {
        convertPPT(inputPath, outputPath, result);
    } else {
        result.errorMsg = "Unsupported format: " + formatType;
    }

    return result;
}

// ============================================================================
// OLE2 Parsing
// ============================================================================

struct OLE2Header {
    uint16_t sectorSize;
    uint16_t miniSectorSize;
    uint32_t numFAT;
    uint32_t firstDirSector;
    uint32_t firstMiniFATSector;
    uint32_t numMiniFAT;
    uint32_t numDIFAT;
    uint32_t DIFAT[109];
};

struct OLE2DirectoryEntry {
    char name[64];
    uint16_t nameLength;
    uint8_t objectType;  // 0=unknown, 1=storage, 2=stream, 5=root
    uint8_t colorFlag;
    uint32_t leftSibling;
    uint32_t rightSibling;
    uint32_t child;
    uint8_t clsid[16];
    uint32_t stateBits;
    uint64_t creationTime;
    uint64_t modifiedTime;
    uint32_t startSector;
    uint64_t size;
};

bool OfficeConverter::parseOLE2Header(const uint8_t* data, size_t size, std::vector<OLE2Entry>& entries) {
    OH_LOG_INFO(LOG_APP, "OfficeConverter: parseOLE2Header start, size=%{public}d", (int)size);

    if (size < 512) {
        OH_LOG_ERROR(LOG_APP, "OfficeConverter: File too small, size=%{public}d < 512", (int)size);
        return false;
    }

    // Check signature
    OH_LOG_INFO(LOG_APP, "OfficeConverter: Checking OLE2 signature, first 8 bytes: %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X",
                data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7]);

    if (memcmp(data, OLE2_SIGNATURE, 8) != 0) {
        OH_LOG_ERROR(LOG_APP, "OfficeConverter: Invalid OLE2 signature, expected D0 CF 11 E0 A1 B1 1A E1");
        return false;
    }

    OH_LOG_INFO(LOG_APP, "OfficeConverter: OLE2 signature valid, parsing header structure");

    // Parse header fields according to MS-CFB specification (v3 format)
    // Offset 24-25: Minor version (usually 0x003E for v3)
    uint16_t minorVersion = data[24] | (data[25] << 8);

    // Offset 26-27: Major version (0x0003 for v3, 0x0004 for v4)
    uint16_t majorVersion = data[26] | (data[27] << 8);

    // Offset 28-29: Byte order (0xFFFE = little endian)
    uint16_t byteOrder = data[28] | (data[29] << 8);

    // Offset 30-31: Sector size power (typically 9 = 512 bytes for v3, or 12 = 4096 bytes for v4)
    uint16_t sectorSizePower = data[30] | (data[31] << 8);
    uint32_t sectorSize = (sectorSizePower == 0) ? 512 : (1 << sectorSizePower);

    // Offset 32-33: Mini sector size power (typically 6 = 64 bytes)
    uint16_t miniSectorSizePower = data[32] | (data[33] << 8);
    uint32_t miniSectorSize = (miniSectorSizePower == 0) ? 64 : (1 << miniSectorSizePower);

    // Offset 36-43: Reserved (should be 0)
    // Offset 44-47: Total number of FAT sectors
    uint32_t numFAT = data[44] | (data[45] << 8) | (data[46] << 16) | (data[47] << 24);

    // Offset 48-51: First directory sector (0 for v3, usually non-zero for v4)
    uint32_t firstDirSector = data[48] | (data[49] << 8) | (data[50] << 16) | (data[51] << 24);

    // Offset 52-59: Transaction signature number (not used for read-only)
    // Offset 60-63: Mini stream cutoff size (usually 0x1000 = 4096)
    uint32_t miniStreamCutoff = data[60] | (data[61] << 8) | (data[62] << 16) | (data[63] << 24);

    // Offset 64-67: First mini FAT sector (usually 0xFFFFFFFE if no mini FAT)
    uint32_t firstMiniFATSector = data[64] | (data[65] << 8) | (data[66] << 16) | (data[67] << 24);

    // Offset 68-71: Number of mini FAT sectors
    uint32_t numMiniFAT = data[68] | (data[69] << 8) | (data[70] << 16) | (data[71] << 24);

    // Offset 72-75: First DIFAT sector (0xFFFFFFFE if DIFAT fits in header)
    uint32_t firstDIFATSector = data[72] | (data[73] << 8) | (data[74] << 16) | (data[75] << 24);

    // Offset 76-79: Number of DIFAT sectors
    uint32_t numDIFAT = data[76] | (data[77] << 8) | (data[78] << 16) | (data[79] << 24);

    OH_LOG_INFO(LOG_APP, "OfficeConverter: version=%{public}d.%{public}d, byteOrder=0x%{public}04X, sectorSize=%{public}d (power=%{public}d), miniSectorSize=%{public}d",
                (int)majorVersion, (int)minorVersion, byteOrder, (int)sectorSize, (int)sectorSizePower, (int)miniSectorSize);
    OH_LOG_INFO(LOG_APP, "OfficeConverter: numFAT=%{public}d, firstDirSector=%{public}d, numMiniFAT=%{public}d",
                (int)numFAT, (int)firstDirSector, (int)numMiniFAT);

    OH_LOG_INFO(LOG_APP, "OfficeConverter: Reading FAT, numFAT=%{public}d", (int)numFAT);

    // Read FAT (File Allocation Table)
    std::vector<uint32_t> FAT;
    int fatEntriesPerSector = sectorSize / 4;

    // DIFAT array starts at offset 80 in the header, contains 109 entries (each 4 bytes)
    // These specify which sectors contain FAT data
    for (uint32_t i = 0; i < numFAT && i < 109; i++) {
        // DIFAT entries start at offset 80 (after 76-79 which is numDIFAT field)
        uint32_t difatOffset = 80 + i * 4;
        uint32_t fatSector = data[difatOffset] | (data[difatOffset + 1] << 8) |
                            (data[difatOffset + 2] << 16) | (data[difatOffset + 3] << 24);

        OH_LOG_INFO(LOG_APP, "OfficeConverter: DIFAT[%{public}d] = sector %{public}d", (int)i, (int)fatSector);

        size_t fatOffset = 512 + fatSector * sectorSize;
        if (fatOffset + sectorSize > size) {
            OH_LOG_WARN(LOG_APP, "OfficeConverter: FAT sector %{public}d offset %{public}d exceeds file size %{public}d",
                        (int)fatSector, (int)fatOffset, (int)size);
            break;
        }

        for (int j = 0; j < fatEntriesPerSector; j++) {
            uint32_t entryOffset = fatOffset + j * 4;
            uint32_t entry = data[entryOffset] | (data[entryOffset + 1] << 8) |
                            (data[entryOffset + 2] << 16) | (data[entryOffset + 3] << 24);
            FAT.push_back(entry);
        }
    }

    OH_LOG_INFO(LOG_APP, "OfficeConverter: FAT entries read: %{public}d", (int)FAT.size());

    // Read directory entries from first directory sector
    uint32_t dirSector = firstDirSector;
    std::vector<uint32_t> dirChain;
    dirChain.push_back(dirSector);

    OH_LOG_INFO(LOG_APP, "OfficeConverter: First directory sector: %{public}d", (int)dirSector);

    // Follow FAT chain
    int chainCount = 0;
    while (dirSector < FAT.size() && FAT[dirSector] != 0xFFFFFFFE) {  // End of chain marker
        dirSector = FAT[dirSector];
        if (dirChain.size() > 1000) break;  // Safety limit
        dirChain.push_back(dirSector);
        chainCount++;
    }

    OH_LOG_INFO(LOG_APP, "OfficeConverter: Directory chain length: %{public}d, chain iterations: %{public}d",
                (int)dirChain.size(), chainCount);

    // Parse directory entries (each sector contains up to 4 entries of 128 bytes)
    int entryCount = 0;
    for (uint32_t sector : dirChain) {
        size_t offset = 512 + sector * sectorSize;
        if (offset + sectorSize > size) {
            OH_LOG_WARN(LOG_APP, "OfficeConverter: Sector offset exceeds file size, sector=%{public}d, offset=%{public}d",
                        (int)sector, (int)offset);
            break;
        }

        for (int i = 0; i < 4 && offset + i * 128 + 128 <= size; i++) {
            size_t entryOffset = offset + i * 128;

            // Directory entry structure (128 bytes):
            // Offset 0-63: Entry name (UTF-16LE, max 32 chars)
            // Offset 64-65: Name length in bytes (including null terminator)
            // Offset 66: Object type (0=unknown, 1=storage, 2=stream, 5=root)
            // Offset 67: Color flag (0=red, 1=black)
            // Offset 68-71: Left sibling
            // Offset 72-75: Right sibling
            // Offset 76-79: Child
            // Offset 80-95: CLSID (16 bytes)
            // Offset 96-99: State bits
            // Offset 100-107: Creation time
            // Offset 108-115: Modified time
            // Offset 116-119: Start sector
            // Offset 120-127: Size (64-bit for v4, but we use 32-bit for compatibility)

            uint8_t objectType = data[entryOffset + 66];
            if (objectType == 0) continue;  // Empty/unused entry

            entryCount++;

            // Name length at offset 64-65 (in bytes, including null terminator)
            uint16_t nameLength = data[entryOffset + 64] | (data[entryOffset + 65] << 8);

            // Decode name (UTF-16LE to ASCII/UTF-8)
            // nameLength is total bytes including null terminator
            // Each UTF-16 char is 2 bytes, so actual chars = nameLength / 2 - 1 (minus null)
            std::string name;
            if (nameLength > 2 && nameLength <= 64) {
                // Process UTF-16LE characters, skip null terminator at end
                int charCount = (nameLength / 2) - 1;  // Number of actual characters
                for (int j = 0; j < charCount && j < 32; j++) {
                    size_t charOffset = entryOffset + j * 2;
                    if (charOffset + 1 >= size) break;
                    uint16_t utf16Char = data[charOffset] | (data[charOffset + 1] << 8);

                    // Handle ASCII and common characters
                    if (utf16Char >= 32 && utf16Char < 127) {
                        name += (char)utf16Char;
                    } else if (utf16Char == 0) {
                        // Null character, skip
                        break;
                    } else if (utf16Char >= 0x4E00 && utf16Char <= 0x9FFF) {
                        // Chinese character - convert to UTF-8
                        name += (char)(0xE0 | (utf16Char >> 12));
                        name += (char)(0x80 | ((utf16Char >> 6) & 0x3F));
                        name += (char)(0x80 | (utf16Char & 0x3F));
                    }
                }
            }

            // Trim trailing whitespace/control chars from name
            while (!name.empty() && (name.back() < 32 || name.back() == ' ')) {
                name.pop_back();
            }

            // Start sector at offset 116-119
            uint32_t startSector = data[entryOffset + 116] | (data[entryOffset + 117] << 8) |
                                   (data[entryOffset + 118] << 16) | (data[entryOffset + 119] << 24);

            // Size at offset 120-127 (use lower 32 bits for v3 files)
            uint32_t entrySize = data[entryOffset + 120] | (data[entryOffset + 121] << 8) |
                                (data[entryOffset + 122] << 16) | (data[entryOffset + 123] << 24);

            OH_LOG_INFO(LOG_APP, "OfficeConverter: DirEntry %{public}d: name='%{public}s', type=%{public}d, size=%{public}d, startSector=%{public}d",
                        entryCount, name.c_str(), (int)objectType, (int)entrySize, (int)startSector);

            OLE2Entry entry;
            entry.name = name;
            entry.size = entrySize;
            entry.offset = startSector;
            entry.isStream = (objectType == 2);
            entry.isStorage = (objectType == 1);

            entries.push_back(entry);
        }
    }

    OH_LOG_INFO(LOG_APP, "OfficeConverter: parseOLE2Header done, entries=%{public}d", (int)entries.size());
    return true;
}

bool OfficeConverter::readOLE2Stream(const uint8_t* data, size_t size, const OLE2Entry& entry,
                                      std::vector<uint8_t>& streamData) {
    // Parse header again for sector size
    uint16_t sectorSizePower = data[30] | (data[31] << 8);
    uint32_t sectorSize = 1 << sectorSizePower;

    // Read FAT
    std::vector<uint32_t> FAT;
    int fatEntriesPerSector = sectorSize / 4;

    // First 109 FAT sectors are in header
    for (int i = 0; i < 109; i++) {
        uint32_t fatSector;
        memcpy(&fatSector, data + 76 + i * 4, 4);
        if (fatSector >= 0xFFFFFFFE) continue;

        size_t fatOffset = 512 + fatSector * sectorSize;
        if (fatOffset + sectorSize > size) continue;

        for (int j = 0; j < fatEntriesPerSector; j++) {
            uint32_t fatEntry;
            memcpy(&fatEntry, data + fatOffset + j * 4, 4);
            FAT.push_back(fatEntry);
        }
    }

    // Follow sector chain
    uint32_t sector = entry.offset;
    streamData.clear();

    int maxIterations = 10000;  // Safety limit
    uint32_t lastValidSector = sector;  // Track last valid sector for fallback

    while (sector < FAT.size() && maxIterations-- > 0) {
        // Check for end-of-chain or invalid markers
        uint32_t fatEntry = (sector < FAT.size()) ? FAT[sector] : 0xFFFFFFFE;

        if (fatEntry == 0xFFFFFFFE) {  // ENDOFCHAIN - normal end
            break;
        }
        if (fatEntry == 0xFFFFFFFD) {  // FREESECT - broken chain
            OH_LOG_WARN(LOG_APP, "OfficeConverter: FAT chain broken at sector %{public}d (FREESECT), attempting direct read",
                        (int)sector);
            break;
        }

        size_t sectorOffset = 512 + sector * sectorSize;
        if (sectorOffset + sectorSize > size) {
            OH_LOG_WARN(LOG_APP, "OfficeConverter: Sector offset %{public}d exceeds file size", (int)sectorOffset);
            break;
        }

        size_t bytesToCopy = std::min((size_t)sectorSize, entry.size - streamData.size());
        streamData.insert(streamData.end(), data + sectorOffset, data + sectorOffset + bytesToCopy);

        // Check if we've read enough
        if (streamData.size() >= entry.size) {
            break;
        }

        lastValidSector = sector;
        sector = fatEntry;
    }

    // If FAT chain ended prematurely, try direct contiguous read as fallback
    if (streamData.size() < entry.size) {
        OH_LOG_INFO(LOG_APP, "OfficeConverter: FAT chain incomplete, got %{public}d bytes, expected %{public}d, trying direct read",
                    (int)streamData.size(), (int)entry.size);

        // Clear and try direct read from start sector
        streamData.clear();
        uint32_t sectorsNeeded = (entry.size / sectorSize) + 1;

        for (uint32_t i = 0; i < sectorsNeeded && streamData.size() < entry.size; i++) {
            uint32_t currentSector = entry.offset + i;
            size_t sectorOffset = 512 + currentSector * sectorSize;

            if (sectorOffset + sectorSize > size) {
                OH_LOG_WARN(LOG_APP, "OfficeConverter: Direct read sector %{public}d offset %{public}d exceeds file",
                            (int)currentSector, (int)sectorOffset);
                break;
            }

            size_t bytesToCopy = std::min((size_t)sectorSize, entry.size - streamData.size());
            streamData.insert(streamData.end(), data + sectorOffset, data + sectorOffset + bytesToCopy);
        }

        OH_LOG_INFO(LOG_APP, "OfficeConverter: Direct read completed, got %{public}d bytes (expected %{public}d)",
                    (int)streamData.size(), (int)entry.size);
    }

    return streamData.size() > 0;
}

// ============================================================================
// XLS Parsing (BIFF8 format)
// ============================================================================

// Shared String Table
static std::vector<std::string> g_sharedStrings;

// XF (Extended Format) - track for cell styling
// Map xfIndex -> fmtIndex (format code) for style generation
static std::map<uint16_t, uint16_t> g_xfToFmtMap;  // xfIndex -> fmtIndex
static std::set<uint16_t> g_percentageFmtIndexes;  // FORMAT indexes that are percentage
static uint16_t g_xfRecordCount = 0;  // Count of XF records encountered

static uint16_t readU16(const uint8_t* data) {
    return data[0] | (data[1] << 8);
}

static uint32_t readU32(const uint8_t* data) {
    return data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
}

/**
 * ShortXLUnicodeString - Used by BOUNDSHEET and some other records
 * MS-XLS Spec: Structure is cch(1 byte) + flags(1 byte) + rgb(variable)
 * Unlike XLUnicodeRichExtendedString, this has NO rich text (cRun) or ExtRst support
 */
static std::string readShortXLUnicodeString(const uint8_t* data, size_t maxLen) {
    // ShortXLUnicodeString: cch(1 byte) + flags(1 byte) + rgb(variable)
    // Used by: BOUNDSHEET sheet names
    // flags: bit 0 = fHighByte (1=UTF-16, 0=single byte)
    if (maxLen < 2) return "";

    uint8_t charCount = data[0];  // 1-byte cch (number of characters, NOT bytes)
    uint8_t flags = data[1];
    bool isUTF16 = (flags & 0x01) != 0;

    // Calculate string byte size
    size_t strByteSize = isUTF16 ? charCount * 2 : charCount;
    size_t headerSize = 2;  // cch(1) + flags(1)

    if (headerSize + strByteSize > maxLen) {
        strByteSize = maxLen - headerSize;
    }

    // Read string data (convert UTF-16LE to UTF-8)
    std::string result;

    if (isUTF16) {
        for (size_t i = 0; i + 1 < strByteSize; i += 2) {
            uint16_t ch = readU16(data + headerSize + i);

            // Skip null characters and control characters
            if (ch == 0 || (ch < 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D)) {
                continue;
            }

            // Convert UTF-16 to UTF-8
            if (ch < 0x80) {
                result += (char)ch;
            } else if (ch < 0x800) {
                result += (char)(0xC0 | (ch >> 6));
                result += (char)(0x80 | (ch & 0x3F));
            } else {
                result += (char)(0xE0 | (ch >> 12));
                result += (char)(0x80 | ((ch >> 6) & 0x3F));
                result += (char)(0x80 | (ch & 0x3F));
            }
        }
    } else {
        for (size_t i = 0; i < strByteSize; i++) {
            uint8_t c = data[headerSize + i];
            if (c == 0 || (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D)) {
                continue;
            }
            if (c < 0x80) {
                result += (char)c;
            } else {
                // Convert Latin-1 to UTF-8
                result += (char)(0xC0 | (c >> 6));
                result += (char)(0x80 | (c & 0x3F));
            }
        }
    }

    return result;
}

static std::string readXLUnicodeString(const uint8_t* data, size_t maxLen) {
    // MS-XLS Official Specification: XLUnicodeRichExtendedString structure
    // Order: cch(2) → flags(1) → cRun(2,opt) → cbExtRst(4,opt) → rgb(string) → rgRun(format) → ExtRst
    // IMPORTANT: String data (rgb) comes BEFORE rgRun (FormatRun array)!
    // Used by: SST, CONTINUE, LABELSST, FORMAT, etc.

    if (maxLen < 3) return "";

    uint16_t charCount = readU16(data);  // Number of characters (NOT bytes)
    uint8_t flags = data[2];

    // Flags bit layout (MS-XLS spec):
    // bit 0 (A): fHighByte - 0x01 = UTF-16, 0x00 = single byte
    // bit 1 (B): reserved1 - MUST be 0
    // bit 2 (C): fExtSt - 0x04 = has ExtRst (phonetic data)
    // bit 3 (D): fRichSt - 0x08 = has rgRun (rich text formatting)
    // bits 4-7: reserved2 - MUST be 0

    bool isUTF16 = (flags & 0x01) != 0;
    bool hasExtRst = (flags & 0x04) != 0;
    bool hasRichText = (flags & 0x08) != 0;

    // Calculate header size BEFORE string data (rgb)
    // Per MS-XLS spec: header = cch(2) + flags(1) + cRun(2,if fRichSt) + cbExtRst(4,if fExtSt)
    size_t headerSize = 3;  // cch(2) + flags(1)

    uint16_t cRun = 0;      // Number of FormatRun structures
    uint32_t cbExtRst = 0;  // Size of ExtRst structure

    if (hasRichText) {
        if (headerSize + 2 > maxLen) return "";
        cRun = readU16(data + headerSize);  // Read cRun count
        headerSize += 2;  // Add cRun field size to header
    }

    if (hasExtRst) {
        if (headerSize + 4 > maxLen) return "";
        cbExtRst = readU32(data + headerSize);  // Read cbExtRst size
        headerSize += 4;  // Add cbExtRst field size to header
    }

    // Now headerSize points to the START of rgb (string data)
    // Calculate string byte size
    size_t strByteSize = isUTF16 ? charCount * 2 : charCount;

    if (headerSize + strByteSize > maxLen) {
        strByteSize = maxLen - headerSize;
    }

    // Read string data from rgb field (convert UTF-16LE to UTF-8)
    std::string result;

    if (isUTF16) {
        for (size_t i = 0; i + 1 < strByteSize; i += 2) {
            uint16_t ch = readU16(data + headerSize + i);

            // Skip null characters and control characters (invalid in XML)
            if (ch == 0 || (ch < 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D)) {
                continue;
            }

            // Convert UTF-16 to UTF-8
            if (ch < 0x80) {
                result += (char)ch;
            } else if (ch < 0x800) {
                result += (char)(0xC0 | (ch >> 6));
                result += (char)(0x80 | (ch & 0x3F));
            } else {
                result += (char)(0xE0 | (ch >> 12));
                result += (char)(0x80 | ((ch >> 6) & 0x3F));
                result += (char)(0x80 | (ch & 0x3F));
            }
        }
    } else {
        for (size_t i = 0; i < strByteSize; i++) {
            uint8_t c = data[headerSize + i];
            if (c == 0 || (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D)) {
                continue;
            }
            if (c < 0x80) {
                result += (char)c;
            } else {
                // Convert Latin-1 to UTF-8
                result += (char)(0xC0 | (c >> 6));
                result += (char)(0x80 | (c & 0x3F));
            }
        }
    }

    // Note: We skip rgRun (cRun * 4 bytes) and ExtRst (cbExtRst bytes) as they
    // contain only formatting/phonetic metadata, not the actual display string.
    // The actual string content is in rgb field which we've already extracted.

    return result;
}

bool OfficeConverter::convertXLS(const std::string& inputPath, const std::string& outputPath,
                                  ConversionResult& result) {
    OH_LOG_INFO(LOG_APP, "OfficeConverter: convertXLS start, input=%{public}s", inputPath.c_str());

    // Remove file:// URI prefix if present and ensure absolute path
    std::string filePath = inputPath;
    if (filePath.find("file://") == 0) {
        filePath = filePath.substr(7);
        OH_LOG_INFO(LOG_APP, "OfficeConverter: Removed file:// prefix, path=%{public}s", filePath.c_str());
    }
    // Ensure path starts with / for absolute path
    if (filePath.length() > 0 && filePath[0] != '/') {
        filePath = "/" + filePath;
        OH_LOG_INFO(LOG_APP, "OfficeConverter: Added / prefix, path=%{public}s", filePath.c_str());
    }

    OH_LOG_INFO(LOG_APP, "OfficeConverter: Final filePath=%{public}s", filePath.c_str());

    // Read file
    FILE* file = fopen(filePath.c_str(), "rb");
    if (!file) {
        OH_LOG_ERROR(LOG_APP, "OfficeConverter: Cannot open file: %{public}s", filePath.c_str());
        result.errorMsg = "Cannot open file: " + filePath;
        return false;
    }

    OH_LOG_INFO(LOG_APP, "OfficeConverter: File opened successfully");

    fseek(file, 0, SEEK_END);
    size_t fileSize = ftell(file);
    fseek(file, 0, SEEK_SET);

    std::vector<uint8_t> fileData(fileSize);
    fread(fileData.data(), 1, fileSize, file);
    fclose(file);

    // Parse OLE2 structure
    std::vector<OLE2Entry> entries;
    if (!parseOLE2Header(fileData.data(), fileSize, entries)) {
        result.errorMsg = "Failed to parse OLE2 header";
        return false;
    }

    // Log all found streams for debugging
    OH_LOG_INFO(LOG_APP, "OfficeConverter: Found %{public}d OLE2 entries", (int)entries.size());
    for (const auto& entry : entries) {
        OH_LOG_INFO(LOG_APP, "OfficeConverter: Entry '%{public}s', isStream=%{public}d, size=%{public}d",
                    entry.name.c_str(), (int)entry.isStream, (int)entry.size);
    }

    // Find Workbook stream
    const OLE2Entry* workbookEntry = nullptr;
    for (const auto& entry : entries) {
        if (entry.name == "Workbook" || entry.name == "Book") {
            workbookEntry = &entry;
            break;
        }
    }

    if (!workbookEntry) {
        result.errorMsg = "Workbook stream not found";
        return false;
    }

    // Read Workbook stream
    std::vector<uint8_t> workbookData;
    if (!readOLE2Stream(fileData.data(), fileSize, *workbookEntry, workbookData)) {
        result.errorMsg = "Failed to read Workbook stream";
        return false;
    }

    // Parse BIFF records - First pass: Globals (SST, BOUNDSHEET)
    std::vector<XLSSheet> sheets;
    std::map<uint32_t, int> sheetOffsetToIndex;  // Map BOUNDSHEET offset to sheet index
    g_sharedStrings.clear();
    g_xfToFmtMap.clear();
    g_percentageFmtIndexes.clear();
    g_xfRecordCount = 0;

    OH_LOG_INFO(LOG_APP, "OfficeConverter: Starting BIFF parsing, workbook size=%{public}d", (int)workbookData.size());

    // First pass: Parse globals to get SST and sheet offsets
    size_t pos = 0;
    while (pos + 4 <= workbookData.size()) {
        uint16_t recordType = readU16(workbookData.data() + pos);
        uint16_t recordSize = readU16(workbookData.data() + pos + 2);
        pos += 4;

        if (pos + recordSize > workbookData.size()) {
            OH_LOG_WARN(LOG_APP, "OfficeConverter: Record exceeds data at pos %{public}d", (int)pos);
            break;
        }

        const uint8_t* recordData = workbookData.data() + pos;

        switch (recordType) {
            case 0x0809:  // BOF (Beginning of File/Workbook/Sheet)
                {
                    // BOF structure: version(2), type(2), build(2), buildYear(2)...
                    uint16_t bofVersion = readU16(recordData);
                    uint16_t bofType = readU16(recordData + 2);  // 0x0005=Workbook, 0x0006=Sheet, 0x0010=Chart
                    OH_LOG_INFO(LOG_APP, "OfficeConverter: BOF at %{public}d, version=%{public}d, type=%{public}d",
                                (int)(pos - 4), bofVersion, bofType);
                }
                break;

            case 0x00FC:  // SST (Shared String Table) - CRITICAL for data
                {
                    uint32_t totalStrings = readU32(recordData);
                    uint32_t uniqueStrings = readU32(recordData + 4);
                    OH_LOG_INFO(LOG_APP, "OfficeConverter: SST record, total=%{public}d, unique=%{public}d, recordSize=%{public}d",
                                (int)totalStrings, (int)uniqueStrings, (int)recordSize);

                    // Parse all shared strings using BIFF8 format
                    // SST may be followed by CONTINUE records (0x003C) when data exceeds record size limit

                    // Track state for strings that span across SST/CONTINUE boundaries
                    std::string partialString;      // In-progress string (started in SST, continued in CONTINUE)
                    bool partialIsUTF16 = false;    // Encoding of partial string
                    uint16_t partialCharsLeft = 0;  // Remaining characters to read
                    size_t partialHeaderLeft = 0;   // Remaining header bytes (rich text/extended data)
                    bool hasPartialString = false;  // Are we in middle of a string?

                    size_t strPos = 8;  // Skip header (totalStrings + uniqueStrings)
                    uint32_t stringsParsed = 0;

                    // Parse strings from SST record (using MS-XLS spec structure)
                    // MS-XLS XLUnicodeRichExtendedString: cch(2) → flags(1) → cRun(2,opt) → cbExtRst(4,opt) → rgb(string) → rgRun(format) → ExtRst
                    while (stringsParsed < uniqueStrings && strPos < (size_t)recordSize) {
                        // Check if we have enough bytes for string header (min 3 bytes: length + flags)
                        if (strPos + 3 > (size_t)recordSize) {
                            // Not enough data even for header - this shouldn't happen
                            OH_LOG_WARN(LOG_APP, "OfficeConverter: SST truncated at strPos=%{public}d, remaining=%{public}d",
                                        (int)strPos, (int)((size_t)recordSize - strPos));
                            break;
                        }

                        // Parse string header per MS-XLS spec
                        uint16_t charCount = readU16(recordData + strPos);
                        uint8_t flags = recordData[strPos + 2];
                        bool isUTF16 = (flags & 0x01) != 0;
                        bool hasRichText = (flags & 0x08) != 0;  // fRichSt
                        bool hasExtRst = (flags & 0x04) != 0;    // fExtSt

                        // Header size BEFORE string data (rgb): cch(2) + flags(1) + cRun(2,opt) + cbExtRst(4,opt)
                        size_t headerSize = 3;  // cch(2) + flags(1)

                        uint16_t cRun = 0;      // Number of FormatRun structures
                        uint32_t cbExtRst = 0;  // Size of ExtRst structure

                        if (hasRichText) {
                            if (strPos + headerSize + 2 <= (size_t)recordSize) {
                                cRun = readU16(recordData + strPos + headerSize);
                                headerSize += 2;  // Add cRun field to header
                            } else {
                                // Header incomplete - will continue in CONTINUE
                                hasPartialString = true;
                                break;
                            }
                        }

                        if (hasExtRst) {
                            if (strPos + headerSize + 4 <= (size_t)recordSize) {
                                cbExtRst = readU32(recordData + strPos + headerSize);
                                headerSize += 4;  // Add cbExtRst field to header
                            } else {
                                hasPartialString = true;
                                break;
                            }
                        }

                        // Calculate string data size (rgb field)
                        size_t dataBytes = isUTF16 ? charCount * 2 : charCount;

                        // Total string size = header + dataBytes + rgRun(cRun*4) + ExtRst(cbExtRst)
                        size_t totalStringSize = headerSize + dataBytes + (cRun * 4) + cbExtRst;

                        // Check if entire string fits in remaining SST data
                        if (strPos + totalStringSize <= (size_t)recordSize) {
                            // Complete string - extract it using readXLUnicodeString
                            std::string str = readXLUnicodeString(recordData + strPos, recordSize - strPos);
                            g_sharedStrings.push_back(str);
                            stringsParsed++;
                            strPos += totalStringSize;
                            hasPartialString = false;
                        } else {
                            // String is truncated - data spans into CONTINUE
                            // Read what we can from SST
                            size_t availableData = (size_t)recordSize - strPos;

                            if (availableData >= headerSize) {
                                // Header complete, but string data is truncated
                                size_t availableDataBytes = availableData - headerSize;
                                // Account for data that might be truncated before rgRun/ExtRst
                                // We can only read up to the string data portion
                                size_t readableDataBytes = std::min(availableDataBytes, dataBytes);
                                size_t charsAvailable = isUTF16 ? (readableDataBytes / 2) : readableDataBytes;

                                // Extract partial string from available data (rgb field starts at headerSize)
                                const uint8_t* strDataStart = recordData + strPos + headerSize;
                                if (isUTF16) {
                                    for (size_t i = 0; i + 1 < readableDataBytes; i += 2) {
                                        uint16_t ch = readU16(strDataStart + i);
                                        if (ch == 0 || (ch < 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D)) continue;
                                        if (ch < 0x80) partialString += (char)ch;
                                        else if (ch < 0x800) {
                                            partialString += (char)(0xC0 | (ch >> 6));
                                            partialString += (char)(0x80 | (ch & 0x3F));
                                        } else {
                                            partialString += (char)(0xE0 | (ch >> 12));
                                            partialString += (char)(0x80 | ((ch >> 6) & 0x3F));
                                            partialString += (char)(0x80 | (ch & 0x3F));
                                        }
                                    }
                                } else {
                                    for (size_t i = 0; i < readableDataBytes; i++) {
                                        uint8_t c = strDataStart[i];
                                        if (c == 0 || (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D)) continue;
                                        if (c < 0x80) partialString += (char)c;
                                        else {
                                            partialString += (char)(0xC0 | (c >> 6));
                                            partialString += (char)(0x80 | (c & 0x3F));
                                        }
                                    }
                                }

                                partialCharsLeft = charCount - charsAvailable;
                            } else {
                                // Header also truncated - very rare case
                                partialCharsLeft = charCount;
                            }

                            partialIsUTF16 = isUTF16;
                            hasPartialString = true;

                            OH_LOG_INFO(LOG_APP, "OfficeConverter: String %{public}d truncated in SST, charsLeft=%{public}d, isUTF16=%{public}d",
                                        (int)stringsParsed, (int)partialCharsLeft, (int)partialIsUTF16);
                            break;
                        }
                    }

                    // Check for CONTINUE records following SST
                    size_t continuePos = pos + recordSize;
                    while (stringsParsed < uniqueStrings && continuePos + 4 <= workbookData.size()) {
                        uint16_t contType = readU16(workbookData.data() + continuePos);
                        uint16_t contSize = readU16(workbookData.data() + continuePos + 2);

                        if (contType != 0x003C) {  // Not CONTINUE record
                            break;
                        }

                        // Skip record header
                        continuePos += 4;
                        if (continuePos + contSize > workbookData.size()) {
                            break;
                        }

                        OH_LOG_INFO(LOG_APP, "OfficeConverter: SST CONTINUE record at %{public}d, size=%{public}d, strings so far=%{public}d, strings left=%{public}d",
                                    (int)(continuePos - 4), (int)contSize, (int)stringsParsed, (int)(uniqueStrings - stringsParsed));

                        const uint8_t* contData = workbookData.data() + continuePos;
                        size_t dataOffset = 0;

                        // Handle partial string continuation
                        if (hasPartialString && partialCharsLeft > 0) {
                            // CONTINUE starts with encoding flag (0x00 = 8-bit, 0x01 = 16-bit)
                            // This indicates the encoding of the continuation data
                            uint8_t encodingFlag = contData[0];
                            dataOffset = 1;  // Skip encoding flag

                            OH_LOG_INFO(LOG_APP, "OfficeConverter: CONTINUE continuing partial string, encoding=0x%{public}02X, charsLeft=%{public}d",
                                        encodingFlag, (int)partialCharsLeft);

                            // The encoding flag overrides the original string encoding for continuation
                            bool contIsUTF16 = (encodingFlag == 0x01);

                            // Read remaining characters
                            size_t bytesNeeded = contIsUTF16 ? partialCharsLeft * 2 : partialCharsLeft;
                            size_t bytesAvailable = std::min(bytesNeeded, (size_t)contSize - dataOffset);
                            size_t charsAvailable = contIsUTF16 ? (bytesAvailable / 2) : bytesAvailable;

                            const uint8_t* contStrData = contData + dataOffset;
                            if (contIsUTF16) {
                                for (size_t i = 0; i + 1 < bytesAvailable; i += 2) {
                                    uint16_t ch = readU16(contStrData + i);
                                    if (ch == 0 || (ch < 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D)) continue;
                                    if (ch < 0x80) partialString += (char)ch;
                                    else if (ch < 0x800) {
                                        partialString += (char)(0xC0 | (ch >> 6));
                                        partialString += (char)(0x80 | (ch & 0x3F));
                                    } else {
                                        partialString += (char)(0xE0 | (ch >> 12));
                                        partialString += (char)(0x80 | ((ch >> 6) & 0x3F));
                                        partialString += (char)(0x80 | (ch & 0x3F));
                                    }
                                }
                            } else {
                                for (size_t i = 0; i < bytesAvailable; i++) {
                                    uint8_t c = contStrData[i];
                                    if (c == 0 || (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D)) continue;
                                    if (c < 0x80) partialString += (char)c;
                                    else {
                                        partialString += (char)(0xC0 | (c >> 6));
                                        partialString += (char)(0x80 | (c & 0x3F));
                                    }
                                }
                            }

                            dataOffset += bytesAvailable;
                            partialCharsLeft -= charsAvailable;

                            // Check if partial string is complete
                            if (partialCharsLeft == 0) {
                                g_sharedStrings.push_back(partialString);
                                stringsParsed++;
                                partialString.clear();
                                hasPartialString = false;
                            }
                        }

                        // Parse remaining strings from CONTINUE (complete strings) - per MS-XLS spec
                        while (stringsParsed < uniqueStrings && dataOffset + 3 <= (size_t)contSize) {
                            uint16_t charCount = readU16(contData + dataOffset);
                            uint8_t flags = contData[dataOffset + 2];

                            // Sanity check: charCount should be reasonable (< 10000)
                            if (charCount > 10000) {
                                OH_LOG_WARN(LOG_APP, "OfficeConverter: CONTINUE invalid charCount=%{public}d at offset %{public}d, stopping",
                                            (int)charCount, (int)dataOffset);
                                break;
                            }

                            // Parse per MS-XLS spec for XLUnicodeRichExtendedString
                            bool isUTF16 = (flags & 0x01) != 0;
                            bool hasRichText = (flags & 0x08) != 0;  // fRichSt
                            bool hasExtRst = (flags & 0x04) != 0;    // fExtSt

                            // Header size BEFORE string data: cch(2) + flags(1) + cRun(2,opt) + cbExtRst(4,opt)
                            size_t headerSize = 3;

                            uint16_t cRun = 0;
                            uint32_t cbExtRst = 0;

                            if (hasRichText) {
                                if (dataOffset + headerSize + 2 <= (size_t)contSize) {
                                    cRun = readU16(contData + dataOffset + headerSize);
                                    headerSize += 2;
                                } else {
                                    // Not enough data - truncated
                                    break;
                                }
                            }

                            if (hasExtRst) {
                                if (dataOffset + headerSize + 4 <= (size_t)contSize) {
                                    cbExtRst = readU32(contData + dataOffset + headerSize);
                                    headerSize += 4;
                                } else {
                                    break;
                                }
                            }

                            // Calculate string data size (rgb field)
                            size_t dataBytes = isUTF16 ? charCount * 2 : charCount;

                            // Total string size = header + dataBytes + rgRun(cRun*4) + ExtRst(cbExtRst)
                            size_t totalStringSize = headerSize + dataBytes + (cRun * 4) + cbExtRst;

                            // Check if string fits in remaining CONTINUE data
                            if (dataOffset + totalStringSize > (size_t)contSize) {
                                // String is truncated - will continue in next CONTINUE
                                OH_LOG_INFO(LOG_APP, "OfficeConverter: String %{public}d truncated in CONTINUE at offset %{public}d, need %{public}d, have %{public}d",
                                            (int)stringsParsed, (int)dataOffset, (int)totalStringSize, (int)((size_t)contSize - dataOffset));

                                // Extract partial string from available data (rgb field starts at headerSize)
                                if (dataOffset + headerSize <= (size_t)contSize) {
                                    size_t availableData = (size_t)contSize - dataOffset - headerSize;
                                    size_t readableDataBytes = std::min(availableData, dataBytes);
                                    const uint8_t* strDataStart = contData + dataOffset + headerSize;

                                    if (isUTF16) {
                                        for (size_t i = 0; i + 1 < readableDataBytes; i += 2) {
                                            uint16_t ch = readU16(strDataStart + i);
                                            if (ch == 0 || (ch < 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D)) continue;
                                            if (ch < 0x80) partialString += (char)ch;
                                            else if (ch < 0x800) {
                                                partialString += (char)(0xC0 | (ch >> 6));
                                                partialString += (char)(0x80 | (ch & 0x3F));
                                            } else {
                                                partialString += (char)(0xE0 | (ch >> 12));
                                                partialString += (char)(0x80 | ((ch >> 6) & 0x3F));
                                                partialString += (char)(0x80 | (ch & 0x3F));
                                            }
                                        }
                                    } else {
                                        for (size_t i = 0; i < readableDataBytes; i++) {
                                            uint8_t c = strDataStart[i];
                                            if (c == 0 || (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D)) continue;
                                            if (c < 0x80) partialString += (char)c;
                                            else {
                                                partialString += (char)(0xC0 | (c >> 6));
                                                partialString += (char)(0x80 | (c & 0x3F));
                                            }
                                        }
                                    }

                                    partialIsUTF16 = isUTF16;
                                    partialCharsLeft = charCount - (isUTF16 ? (readableDataBytes / 2) : readableDataBytes);
                                    hasPartialString = true;
                                }
                                break;
                            }

                            // Complete string - extract it
                            std::string str = readXLUnicodeString(contData + dataOffset, contSize - dataOffset);
                            g_sharedStrings.push_back(str);
                            stringsParsed++;

                            dataOffset += totalStringSize;
                        }

                        // Move to next potential CONTINUE record
                        continuePos += contSize;
                    }

                    OH_LOG_INFO(LOG_APP, "OfficeConverter: SST parsed, strings=%{public}d (expected %{public}d)",
                                (int)g_sharedStrings.size(), (int)uniqueStrings);
                }
                break;

            case 0x0085:  // BOUNDSHEET (Sheet Information)
                {
                    // BOUNDSHEET record format (MS-XLS spec):
                    // Offset 0-3: sheet BOF position (absolute position in workbook stream)
                    // Offset 4: visibility (0=visible, 1=hidden, 2=very hidden)
                    // Offset 5: sheet type (0=Worksheet, 1=Chart, 2=Macro)
                    // Offset 6+: sheet name (ShortXLUnicodeString format: 1-byte cch + 1-byte flags + data)

                    uint32_t sheetOffset = readU32(recordData);
                    uint8_t visibility = recordData[4];
                    uint8_t sheetType = recordData[5];  // 0=Worksheet, 1=Chart

                    // IMPORTANT: Sheet name uses ShortXLUnicodeString (1-byte cch), NOT XLUnicodeRichExtendedString!
                    std::string sheetName = readShortXLUnicodeString(recordData + 6, recordSize - 6);
                    if (sheetName.empty()) sheetName = "Sheet" + std::to_string(sheets.size() + 1);

                    // Only add Worksheet type sheets (type 0)
                    if (sheetType == 0) {  // Worksheet
                        XLSSheet sheet;
                        sheet.name = sheetName;
                        sheet.maxRow = 0;
                        sheet.maxCol = 0;

                        sheets.push_back(sheet);
                        sheetOffsetToIndex[sheetOffset] = sheets.size() - 1;

                        OH_LOG_INFO(LOG_APP, "OfficeConverter: BOUNDSHEET '%{public}s', offset=%{public}d, index=%{public}d, type=%{public}d",
                                    sheetName.c_str(), (int)sheetOffset, (int)(sheets.size() - 1), (int)sheetType);
                    } else {
                        OH_LOG_INFO(LOG_APP, "OfficeConverter: Skipping BOUNDSHEET '%{public}s' type=%{public}d (not Worksheet)",
                                    sheetName.c_str(), (int)sheetType);
                    }
                }
                break;

            case 0x000A:  // EOF (End of Globals)
                OH_LOG_INFO(LOG_APP, "OfficeConverter: EOF at %{public}d (Globals end)", (int)pos);
                break;

            case 0x00E0:  // XF (Extended Format)
                {
                    // XF record format per MS-XLS:
                    // Offset 0-1: ifnt (font index)
                    // Offset 2-3: ifmt (format index - numFmt)
                    // Store xfIndex -> fmtIndex mapping for XLSX style generation
                    if (recordSize >= 4) {
                        uint16_t xfIndex = g_xfRecordCount;
                        uint16_t fmtIndex = readU16(recordData + 2);

                        // Store mapping
                        g_xfToFmtMap[xfIndex] = fmtIndex;

                        OH_LOG_INFO(LOG_APP, "OfficeConverter: XF[%{public}d] -> fmtIdx=%{public}d",
                                    (int)xfIndex, (int)fmtIndex);
                        g_xfRecordCount++;
                    }
                }
                break;

            case 0x041E:  // FORMAT (Number Format)
                {
                    // FORMAT record format:
                    // Offset 0-1: formatIndex
                    // Offset 2+: format string (XLUnicodeString)
                    if (recordSize >= 4) {
                        uint16_t fmtIndex = readU16(recordData);
                        std::string fmtString = readXLUnicodeString(recordData + 2, recordSize - 2);

                        // Check if format string contains '%'
                        if (fmtString.find('%') != std::string::npos) {
                            g_percentageFmtIndexes.insert(fmtIndex);
                            OH_LOG_INFO(LOG_APP, "OfficeConverter: FORMAT[%{public}d] is percentage: \"%{public}s\"",
                                        (int)fmtIndex, fmtString.c_str());
                        }
                    }
                }
                break;

            default:
                // Skip other global records
                break;
        }

        pos += recordSize;
    }

    OH_LOG_INFO(LOG_APP, "OfficeConverter: Globals parsed, sheets=%{public}d, SST strings=%{public}d",
                (int)sheets.size(), (int)g_sharedStrings.size());

    // Second pass: Parse each sheet's data starting from BOUNDSHEET offsets
    for (size_t sheetIdx = 0; sheetIdx < sheets.size(); sheetIdx++) {
        // Find the sheet's BOF position
        for (const auto& [offset, idx] : sheetOffsetToIndex) {
            if (idx == (int)sheetIdx) {
                OH_LOG_INFO(LOG_APP, "OfficeConverter: Parsing sheet %{public}d '%{public}s}' at offset %{public}d",
                            (int)sheetIdx, sheets[sheetIdx].name.c_str(), (int)offset);

                pos = offset;
                bool inSheet = false;

                // Parse sheet records until EOF
                while (pos + 4 <= workbookData.size()) {
                    uint16_t recordType = readU16(workbookData.data() + pos);
                    uint16_t recordSize = readU16(workbookData.data() + pos + 2);
                    pos += 4;

                    if (pos + recordSize > workbookData.size()) break;

                    const uint8_t* recordData = workbookData.data() + pos;

                    if (recordType == 0x0809) {  // BOF - start of sheet
                        inSheet = true;
                        OH_LOG_INFO(LOG_APP, "OfficeConverter: Sheet BOF at %{public}d", (int)(pos - 4));
                    } else if (recordType == 0x000A) {  // EOF - end of sheet
                        OH_LOG_INFO(LOG_APP, "OfficeConverter: Sheet EOF, cells=%{public}d", (int)sheets[sheetIdx].cells.size());
                        break;
                    } else if (inSheet) {
                        switch (recordType) {
                            case 0x00FD:  // LABELSST (Cell with shared string)
                                {
                                    uint16_t row = readU16(recordData);
                                    uint16_t col = readU16(recordData + 2);
                                    uint16_t xfIndex = readU16(recordData + 4);  // XF at offset 4-5
                                    uint32_t sstIndex = readU32(recordData + 6);

                                    if (sstIndex < g_sharedStrings.size()) {
                                        XLSCell cell;
                                        cell.row = row;
                                        cell.col = col;
                                        cell.value = g_sharedStrings[sstIndex];
                                        cell.type = "string";
                                        cell.sstIndex = sstIndex;  // Store original index
                                        cell.xfIndex = xfIndex;
                                        sheets[sheetIdx].cells.push_back(cell);
                                        sheets[sheetIdx].maxRow = std::max(sheets[sheetIdx].maxRow, (int)row);
                                        sheets[sheetIdx].maxCol = std::max(sheets[sheetIdx].maxCol, (int)col);
                                    }
                                }
                                break;

                            case 0x0203:  // NUMBER (Cell with number)
                                {
                                    uint16_t row = readU16(recordData);
                                    uint16_t col = readU16(recordData + 2);
                                    uint16_t xfIndex = readU16(recordData + 4);  // XF at offset 4-5
                                    double value;
                                    memcpy(&value, recordData + 6, 8);

                                    // If XF is percentage format, multiply by 100
                                    // Note: Do NOT multiply by 100 - percentage values are stored as-is in XLS
                                    // The format string controls how they are displayed

                                    XLSCell cell;
                                    cell.row = row;
                                    cell.col = col;
                                    cell.sstIndex = -1;  // Not from SST
                                    cell.xfIndex = xfIndex;
                                    char buf[32];
                                    if (value == floor(value) && fabs(value) < 1e15) {
                                        snprintf(buf, sizeof(buf), "%.0f", value);
                                    } else {
                                        snprintf(buf, sizeof(buf), "%.6g", value);
                                    }
                                    cell.value = buf;
                                    cell.type = "number";
                                    sheets[sheetIdx].cells.push_back(cell);
                                    sheets[sheetIdx].maxRow = std::max(sheets[sheetIdx].maxRow, (int)row);
                                    sheets[sheetIdx].maxCol = std::max(sheets[sheetIdx].maxCol, (int)col);
                                }
                                break;

                            case 0x0204:  // LABEL (Cell with inline string - BIFF2-7, rare in BIFF8)
                                {
                                    uint16_t row = readU16(recordData);
                                    uint16_t col = readU16(recordData + 2);
                                    uint16_t xfIndex = readU16(recordData + 4);  // XF at offset 4-5
                                    // BIFF8 LABELSST uses SST index; old LABEL uses different format
                                    // string at offset 6
                                    std::string value = readXLUnicodeString(recordData + 6, recordSize - 6);

                                    XLSCell cell;
                                    cell.row = row;
                                    cell.col = col;
                                    cell.sstIndex = -1;  // Inline string, not from SST
                                    cell.xfIndex = xfIndex;
                                    cell.value = value;
                                    cell.type = "string";
                                    sheets[sheetIdx].cells.push_back(cell);
                                    sheets[sheetIdx].maxRow = std::max(sheets[sheetIdx].maxRow, (int)row);
                                    sheets[sheetIdx].maxCol = std::max(sheets[sheetIdx].maxCol, (int)col);
                                }
                                break;

                            case 0x027E:  // RK (Cell with RK number)
                                {
                                    uint16_t row = readU16(recordData);
                                    uint16_t col = readU16(recordData + 2);
                                    uint16_t xfIndex = readU16(recordData + 4);  // XF at offset 4-5
                                    uint32_t rk = readU32(recordData + 6);

                                    // Decode RK number per MS-XLS spec
                                    // RK structure: fX100(bit0) | fInt(bit1) | num(bits2-31)
                                    // fX100=1 means value should be divided by 100
                                    // fInt=1 means num is signed integer, else IEEE float
                                    uint32_t typeBits = rk & 0x03;
                                    double value;

                                    if (typeBits & 0x02) {  // fInt=1: signed integer
                                        // Extract 30-bit signed integer
                                        int32_t intVal = (rk >> 2);
                                        // Handle sign extension (30-bit signed)
                                        if (intVal & 0x20000000) {
                                            intVal = intVal - 0x40000000;
                                        }
                                        value = (double)intVal;
                                    } else {  // fInt=0: IEEE float (30 most significant bits)
                                        union { uint64_t i; double d; } u;
                                        u.i = ((uint64_t)(rk & 0xFFFFFFFC)) << 32;
                                        value = u.d;
                                    }

                                    // fX100=1: divide by 100
                                    if (typeBits & 0x01) {
                                        value /= 100.0;
                                    }

                                    XLSCell cell;
                                    cell.row = row;
                                    cell.col = col;
                                    cell.sstIndex = -1;  // Not from SST
                                    cell.xfIndex = xfIndex;
                                    char buf[32];
                                    if (value == floor(value) && fabs(value) < 1e15) {
                                        snprintf(buf, sizeof(buf), "%.0f", value);
                                    } else {
                                        snprintf(buf, sizeof(buf), "%.6g", value);
                                    }
                                    cell.value = buf;
                                    cell.type = "number";
                                    sheets[sheetIdx].cells.push_back(cell);
                                    sheets[sheetIdx].maxRow = std::max(sheets[sheetIdx].maxRow, (int)row);
                                    sheets[sheetIdx].maxCol = std::max(sheets[sheetIdx].maxCol, (int)col);
                                }
                                break;

                            case 0x00BD:  // MULRK (Multiple RK numbers)
                                {
                                    uint16_t row = readU16(recordData);
                                    uint16_t firstCol = readU16(recordData + 2);
                                    uint16_t lastCol = readU16(recordData + recordSize - 2);

                                    for (uint16_t col = firstCol; col <= lastCol; col++) {
                                        size_t rkOffset = 4 + (col - firstCol) * 6;
                                        if (rkOffset + 6 > (size_t)recordSize) break;

                                        // MULRK RG structure: XF(2) + RK(4)
                                        uint16_t xfIndex = readU16(recordData + rkOffset);
                                        uint32_t rk = readU32(recordData + rkOffset + 2);

                                        // Decode RK per MS-XLS spec
                                        uint32_t typeBits = rk & 0x03;
                                        double value;

                                        if (typeBits & 0x02) {  // fInt=1: integer
                                            int32_t intVal = (rk >> 2);
                                            if (intVal & 0x20000000) {
                                                intVal = intVal - 0x40000000;
                                            }
                                            value = (double)intVal;
                                        } else {  // IEEE float
                                            union { uint64_t i; double d; } u;
                                            u.i = ((uint64_t)(rk & 0xFFFFFFFC)) << 32;
                                            value = u.d;
                                        }

                                        if (typeBits & 0x01) {  // fX100=1: divide by 100
                                            value /= 100.0;
                                        }

                                        XLSCell cell;
                                        cell.row = row;
                                        cell.col = col;
                                        cell.sstIndex = -1;  // Not from SST
                                        cell.xfIndex = xfIndex;
                                        char buf[32];
                                        if (value == floor(value) && fabs(value) < 1e15) {
                                            snprintf(buf, sizeof(buf), "%.0f", value);
                                        } else {
                                            snprintf(buf, sizeof(buf), "%.6g", value);
                                        }
                                        cell.value = buf;
                                        cell.type = "number";
                                        sheets[sheetIdx].cells.push_back(cell);
                                        sheets[sheetIdx].maxRow = std::max(sheets[sheetIdx].maxRow, (int)row);
                                        sheets[sheetIdx].maxCol = std::max(sheets[sheetIdx].maxCol, (int)col);
                                    }
                                }
                                break;

                            case 0x00BE:  // MULBLANK (Multiple blank cells)
                                // Skip blank cells
                                break;

                            case 0x0200:  // DIMENSIONS
                                // Sheet dimensions info
                                break;

                            case 0x00D7:  // DBCELL
                                // Jump markers, skip
                                break;

                            case 0x0023:  // INDEX
                                // Index record, skip
                                break;

                            default:
                                // Unknown record, skip
                                break;
                        }
                    }

                    pos += recordSize;
                }
                break;  // Found and processed this sheet
            }
        }
    }

    OH_LOG_INFO(LOG_APP, "OfficeConverter: BIFF parsing complete, sheets=%{public}d, SST=%{public}d",
                (int)sheets.size(), (int)g_sharedStrings.size());
    for (size_t i = 0; i < sheets.size(); i++) {
        OH_LOG_INFO(LOG_APP, "OfficeConverter: Sheet %{public}d '%{public}s}': %{public}d cells, maxRow=%{public}d, maxCol=%{public}d",
                    (int)(i + 1), sheets[i].name.c_str(), (int)sheets[i].cells.size(),
                    sheets[i].maxRow, sheets[i].maxCol);
    }

    result.sheetCount = sheets.size();

    // Generate XLSX (OOXML)
    if (sheets.empty()) {
        result.errorMsg = "No sheets found in workbook";
        return false;
    }

    // Create XLSX structure
    std::vector<std::pair<std::string, std::vector<uint8_t>>> xlsxFiles;

    // [Content_Types].xml
    std::string contentTypes =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n"
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n"
        "<Default Extension=\"xml\" ContentType=\"application/xml\"/>\n"
        "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>\n"
        "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>\n";
    for (size_t i = 0; i < sheets.size(); i++) {
        contentTypes += "<Override PartName=\"/xl/worksheets/sheet" + std::to_string(i + 1) + ".xml\" "
                       "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>\n";
    }
    contentTypes += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\n"
                    "</Types>";
    xlsxFiles.push_back({"[Content_Types].xml", std::vector<uint8_t>(contentTypes.begin(), contentTypes.end())});

    // _rels/.rels
    std::string rels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>\n"
        "</Relationships>";
    xlsxFiles.push_back({"_rels/.rels", std::vector<uint8_t>(rels.begin(), rels.end())});

    // xl/workbook.xml
    std::string workbook =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\n"
        "<sheets>\n";
    for (size_t i = 0; i < sheets.size(); i++) {
        workbook += "<sheet name=\"" + sheets[i].name + "\" sheetId=\"" + std::to_string(i + 1) +
                    "\" r:id=\"rId" + std::to_string(i + 1) + "\"/>\n";
    }
    workbook += "</sheets>\n</workbook>";
    xlsxFiles.push_back({"xl/workbook.xml", std::vector<uint8_t>(workbook.begin(), workbook.end())});

    // xl/_rels/workbook.xml.rels
    std::string workbookRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n";
    for (size_t i = 0; i < sheets.size(); i++) {
        workbookRels += "<Relationship Id=\"rId" + std::to_string(i + 1) +
                        "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" "
                        "Target=\"worksheets/sheet" + std::to_string(i + 1) + ".xml\"/>\n";
    }
    workbookRels += "<Relationship Id=\"rId" + std::to_string(sheets.size() + 1) +
                    "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" "
                    "Target=\"sharedStrings.xml\"/>\n";
    workbookRels += "<Relationship Id=\"rId" + std::to_string(sheets.size() + 2) +
                    "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" "
                    "Target=\"styles.xml\"/>\n</Relationships>";
    xlsxFiles.push_back({"xl/_rels/workbook.xml.rels", std::vector<uint8_t>(workbookRels.begin(), workbookRels.end())});

    // xl/styles.xml - Create styles only for actually used xfIndexes
    // Step 1: Collect all xfIndexes used by cells
    std::set<uint16_t> usedXfIndexes;
    for (const auto& sheet : sheets) {
        for (const auto& cell : sheet.cells) {
            usedXfIndexes.insert(cell.xfIndex);
        }
    }

    // Step 2: Build mapping: xfIndex -> new cellXfs index (styleIndex)
    // cellXfs[0] is always the default style
    std::map<uint16_t, uint16_t> xfToStyleMap;
    uint16_t nextStyleIndex = 0;

    // Always add default style (xfIndex 0 or General) as style 0
    xfToStyleMap[0] = nextStyleIndex++;
    usedXfIndexes.erase(0);  // Remove 0 from set (already handled)

    // Add other used xfIndexes in order
    for (uint16_t xfIdx : usedXfIndexes) {
        xfToStyleMap[xfIdx] = nextStyleIndex++;
    }

    // Step 3: Update each cell's styleIndex
    for (auto& sheet : sheets) {
        for (auto& cell : sheet.cells) {
            if (xfToStyleMap.count(cell.xfIndex)) {
                cell.styleIndex = xfToStyleMap[cell.xfIndex];
            } else {
                cell.styleIndex = 0;  // Default
            }
        }
    }

    // Step 4: Generate styles.xml with only used styles
    std::string stylesXml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n"
        "<numFmts count=\"0\"/>\n"
        "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>\n"
        "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>\n"
        "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\n"
        "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>\n"
        "<cellXfs count=\"" + std::to_string(nextStyleIndex) + "\">";

    // Add styles in order of styleIndex
    // style 0 = default (numFmtId=0)
    stylesXml += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>";

    // Add other used xfIndexes (sorted in order of their styleIndex)
    for (uint16_t xfIdx : usedXfIndexes) {
        uint16_t fmtId = 0;  // Default "General"
        if (g_xfToFmtMap.count(xfIdx)) {
            fmtId = g_xfToFmtMap[xfIdx];
        }
        // Add applyNumberFormat for non-general formats
        if (fmtId != 0) {
            stylesXml += "<xf numFmtId=\"" + std::to_string(fmtId) + "\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>";
        } else {
            stylesXml += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>";
        }
    }

    stylesXml += "</cellXfs>\n"
                 "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>\n"
                 "<dxfs count=\"0\"/>\n"
                 "</styleSheet>";
    xlsxFiles.push_back({"xl/styles.xml", std::vector<uint8_t>(stylesXml.begin(), stylesXml.end())});

    // xl/sharedStrings.xml - use original SST directly to preserve order
    // Note: g_sharedStrings contains strings in original SST order
    std::string sharedStringsXml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"" +
        std::to_string(g_sharedStrings.size()) + "\" uniqueCount=\"" + std::to_string(g_sharedStrings.size()) + "\">";
    for (const auto& str : g_sharedStrings) {
        // XML escape
        std::string escaped = str;
        size_t pos;
        while ((pos = escaped.find('&')) != std::string::npos) escaped.replace(pos, 1, "&amp;");
        while ((pos = escaped.find('<')) != std::string::npos) escaped.replace(pos, 1, "&lt;");
        while ((pos = escaped.find('>')) != std::string::npos) escaped.replace(pos, 1, "&gt;");
        while ((pos = escaped.find('"')) != std::string::npos) escaped.replace(pos, 1, "&quot;");
        sharedStringsXml += "<si><t>" + escaped + "</t></si>";
    }
    sharedStringsXml += "</sst>";
    xlsxFiles.push_back({"xl/sharedStrings.xml", std::vector<uint8_t>(sharedStringsXml.begin(), sharedStringsXml.end())});

    // xl/worksheets/sheet*.xml
    for (size_t i = 0; i < sheets.size(); i++) {
        std::string worksheet =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n"
            "<sheetData>\n";

        // Sort cells by row
        std::map<int, std::vector<XLSCell>> rowCells;
        for (const auto& cell : sheets[i].cells) {
            rowCells[cell.row].push_back(cell);
        }

        for (auto& [rowNum, cells] : rowCells) {
            worksheet += "<row r=\"" + std::to_string(rowNum + 1) + "\">";
            for (const auto& cell : cells) {
                // Column letter
                std::string colLetter;
                int col = cell.col;
                do {
                    colLetter = (char)('A' + (col % 26)) + colLetter;
                    col = col / 26 - 1;
                } while (col >= 0);

                std::string cellRef = colLetter + std::to_string(rowNum + 1);

                if (cell.type == "string") {
                    // Use original SST index if available, otherwise need inline string
                    if (cell.sstIndex >= 0) {
                        worksheet += "<c r=\"" + cellRef + "\" t=\"s\" s=\"" + std::to_string(cell.styleIndex) + "\"><v>" + std::to_string(cell.sstIndex) + "</v></c>";
                    } else {
                        // Inline string - need to add to sharedStrings or use <is>
                        // For simplicity, add as inline string
                        std::string escaped = cell.value;
                        size_t pos;
                        while ((pos = escaped.find('&')) != std::string::npos) escaped.replace(pos, 1, "&amp;");
                        while ((pos = escaped.find('<')) != std::string::npos) escaped.replace(pos, 1, "&lt;");
                        while ((pos = escaped.find('>')) != std::string::npos) escaped.replace(pos, 1, "&gt;");
                        worksheet += "<c r=\"" + cellRef + "\" t=\"inlineStr\" s=\"" + std::to_string(cell.styleIndex) + "\"><is><t>" + escaped + "</t></is></c>";
                    }
                } else {
                    // Number cell - add style (s) attribute for format
                    worksheet += "<c r=\"" + cellRef + "\" s=\"" + std::to_string(cell.styleIndex) + "\"><v>" + cell.value + "</v></c>";
                }
            }
            worksheet += "</row>\n";
        }

        worksheet += "</sheetData>\n</worksheet>";
        xlsxFiles.push_back({"xl/worksheets/sheet" + std::to_string(i + 1) + ".xml",
                             std::vector<uint8_t>(worksheet.begin(), worksheet.end())});
    }

    // Create ZIP file
    if (!createZIP(outputPath, xlsxFiles)) {
        result.errorMsg = "Failed to create ZIP output";
        return false;
    }

    result.success = true;
    result.outputPath = outputPath;
    return true;
}

// ============================================================================
// DOC Conversion (Minimal implementation)
// ============================================================================

// ============================================================================
// DOC Conversion (Word 97-2003 Binary Format)
// ============================================================================

// FIB (File Information Block) key offsets
// Per MS-DOC specification:
// Offset 0x00-0x01: wIdent (0xA5EC for Word document)
// Offset 0x02-0x03: nFibBack (version)
// Offset 0x18-0x19: fWhichTblStm (0=0Table, 1=1Table)
// ============================================================================
// DOC Conversion (Word 97-2003 Binary Format) - Proper FIB/Piece Table parsing
// ============================================================================

/**
 * Decode UTF-16LE bytes to UTF-8 string
 * @param data Source bytes
 * @param offset Start offset in data
 * @param charCount Number of UTF-16 characters (not bytes)
 * @return UTF-8 encoded string
 */
static std::string decodeUTF16LEtoUTF8(const uint8_t* data, size_t offset, size_t charCount) {
    std::string result;
    for (size_t i = 0; i < charCount; i++) {
        size_t bytePos = offset + i * 2;
        uint16_t ch = data[bytePos] | (data[bytePos + 1] << 8);
        // Skip null chars and control chars except tab/newline/cr/cell mark
        // Keep 0x07 (cell mark) for table detection, skip other low control chars
        if (ch == 0) continue;
        if (ch < 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D && ch != 0x07) continue;
        // Convert to UTF-8
        if (ch < 0x80) {
            result += (char)ch;
        } else if (ch < 0x800) {
            result += (char)(0xC0 | (ch >> 6));
            result += (char)(0x80 | (ch & 0x3F));
        } else {
            result += (char)(0xE0 | (ch >> 12));
            result += (char)(0x80 | ((ch >> 6) & 0x3F));
            result += (char)(0x80 | (ch & 0x3F));
        }
    }
    return result;
}

/**
 * Decode CP1252/ANSI bytes to UTF-8 string
 * @param data Source bytes
 * @param offset Start offset in data
 * @param charCount Number of bytes to decode
 * @return UTF-8 encoded string
 */
static std::string decodeCP1252toUTF8(const uint8_t* data, size_t offset, size_t charCount) {
    // CP1252 to Unicode mapping for bytes 0x80-0x9F (differs from ISO-8859-1)
    static const uint16_t cp1252map[32] = {
        0x20AC, 0x003F, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,  // 0x80-0x87
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x003F, 0x017D, 0x003F,  // 0x88-0x8F
        0x003F, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,  // 0x90-0x97
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x003F, 0x017E, 0x0178   // 0x98-0x9F
    };

    std::string result;
    for (size_t i = 0; i < charCount; i++) {
        uint8_t c = data[offset + i];
        // Keep 0x07 (cell mark) for table detection, skip null and other control chars
        if (c == 0) continue;
        if (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D && c != 0x07) continue;

        uint16_t ch;
        if (c < 0x80) {
            ch = c;
        } else if (c >= 0x80 && c <= 0x9F) {
            ch = cp1252map[c - 0x80];
        } else {
            ch = c;  // 0xA0-0xFF maps directly to Unicode
        }

        if (ch < 0x80) {
            result += (char)ch;
        } else if (ch < 0x800) {
            result += (char)(0xC0 | (ch >> 6));
            result += (char)(0x80 | (ch & 0x3F));
        } else {
            result += (char)(0xE0 | (ch >> 12));
            result += (char)(0x80 | ((ch >> 6) & 0x3F));
            result += (char)(0x80 | (ch & 0x3F));
        }
    }
    return result;
}

/**
 * XML-escape a string
 */
static std::string xmlEscape(const std::string& text) {
    std::string result;
    result.reserve(text.size());
    for (char c : text) {
        switch (c) {
            case '&':  result += "&amp;"; break;
            case '<':  result += "&lt;"; break;
            case '>':  result += "&gt;"; break;
            case '"':  result += "&quot;"; break;
            case '\'': result += "&apos;"; break;
            default:   result += c; break;
        }
    }
    return result;
}

/**
 * Parse the FIB (File Information Block) from the WordDocument stream
 * to locate the Piece Table (CLX) in the Table stream.
 *
 * FIB structure (MS-DOC spec):
 *   FibBase (32 bytes)
 *   csw (2 bytes) + FibRgW (csw * 2 bytes)
 *   cslw (2 bytes) + FibRgLw (cslw * 4 bytes)
 *   cbRgFcLcb (2 bytes) + FibRgFcLcb (cbRgFcLcb * 8 bytes) - pairs of (fc, lcb)
 *
 * The fcClx/lcbClx pair is at index 33 in FibRgFcLcb97 (MS-DOC spec section 2.5.6).
 * The fcPlcfBtePapx/lcbPlcfBtePapx pair is at index 13.
 */
struct FibParseResult {
    bool useTable1;       // fWhichTblStm flag: true = use 1Table, false = use 0Table
    uint32_t fcClx;      // Offset of CLX in the table stream
    uint32_t lcbClx;     // Size of CLX in the table stream
    uint32_t fcPlcfBtePapx;  // Offset of PlcBtePapx in table stream (for PAP parsing)
    uint32_t lcbPlcfBtePapx; // Size of PlcBtePapx
    uint32_t cbMac;      // Count of bytes of main document text
    bool valid;
};

static FibParseResult parseFIB(const std::vector<uint8_t>& wordDocData) {
    FibParseResult fib;
    fib.useTable1 = false;
    fib.fcClx = 0;
    fib.lcbClx = 0;
    fib.fcPlcfBtePapx = 0;
    fib.lcbPlcfBtePapx = 0;
    fib.cbMac = 0;
    fib.valid = false;

    if (wordDocData.size() < 34) {
        OH_LOG_ERROR(LOG_APP, "DOC: WordDocument stream too small (%{public}d bytes)", (int)wordDocData.size());
        return fib;
    }

    // Verify magic (wIdent = 0xA5EC)
    uint16_t wIdent = wordDocData[0] | (wordDocData[1] << 8);
    if (wIdent != 0xA5EC) {
        OH_LOG_WARN(LOG_APP, "DOC: wIdent mismatch: 0x%{public}04X (expected 0xA5EC)", wIdent);
        // Don't return - some files may have slightly different magic
    }

    // FibBase.flags at offset 10 (0x0A)
    // fWhichTblStm is bit 9 (0x0200) of the flags word
    uint16_t flags = wordDocData[0x0A] | (wordDocData[0x0B] << 8);
    fib.useTable1 = (flags & 0x0200) != 0;

    OH_LOG_INFO(LOG_APP, "DOC: FibBase flags=0x%{public}04X, fWhichTblStm=%{public}d (use %{public}s)",
                flags, (int)fib.useTable1, fib.useTable1 ? "1Table" : "0Table");

    // Skip FibBase (32 bytes)
    // Read csw at offset 32
    size_t pos = 32;
    uint16_t csw = wordDocData[pos] | (wordDocData[pos + 1] << 8);
    pos += 2;

    OH_LOG_INFO(LOG_APP, "DOC: csw=%{public}d at pos=%{public}d", (int)csw, (int)pos);

    // Skip FibRgW (csw * 2 bytes)
    pos += csw * 2;

    if (pos + 2 > wordDocData.size()) {
        OH_LOG_ERROR(LOG_APP, "DOC: FIB truncated before cslw at pos=%{public}d", (int)pos);
        return fib;
    }

    // Read cslw
    uint16_t cslw = wordDocData[pos] | (wordDocData[pos + 1] << 8);
    pos += 2;

    OH_LOG_INFO(LOG_APP, "DOC: cslw=%{public}d at pos=%{public}d", (int)cslw, (int)pos);

    // Read FibRgLw - the first field is cbMac (count of bytes of text)
    if (cslw >= 1 && pos + 4 <= wordDocData.size()) {
        fib.cbMac = wordDocData[pos] | (wordDocData[pos + 1] << 8) |
                    (wordDocData[pos + 2] << 16) | (wordDocData[pos + 3] << 24);
        OH_LOG_INFO(LOG_APP, "DOC: cbMac=%{public}d", (int)fib.cbMac);
    }

    // Skip FibRgLw (cslw * 4 bytes)
    pos += cslw * 4;

    if (pos + 2 > wordDocData.size()) {
        OH_LOG_ERROR(LOG_APP, "DOC: FIB truncated before cbRgFcLcb at pos=%{public}d", (int)pos);
        return fib;
    }

    // Read cbRgFcLcb (number of FcLcb pairs)
    uint16_t cbRgFcLcb = wordDocData[pos] | (wordDocData[pos + 1] << 8);
    pos += 2;

    OH_LOG_INFO(LOG_APP, "DOC: cbRgFcLcb=%{public}d at pos=%{public}d", (int)cbRgFcLcb, (int)pos);

    // fcPlcfBtePapx/lcbPlcfBtePapx is pair index 13 (for PAP parsing - table row detection)
    if (cbRgFcLcb >= 14 && pos + 14 * 8 <= wordDocData.size()) {
        size_t papxPairOffset = pos + 13 * 8;
        fib.fcPlcfBtePapx = wordDocData[papxPairOffset] | (wordDocData[papxPairOffset + 1] << 8) |
                           (wordDocData[papxPairOffset + 2] << 16) | (wordDocData[papxPairOffset + 3] << 24);
        fib.lcbPlcfBtePapx = wordDocData[papxPairOffset + 4] | (wordDocData[papxPairOffset + 5] << 8) |
                            (wordDocData[papxPairOffset + 6] << 16) | (wordDocData[papxPairOffset + 7] << 24);
        OH_LOG_INFO(LOG_APP, "DOC: fcPlcfBtePapx=%{public}d, lcbPlcfBtePapx=%{public}d",
                    (int)fib.fcPlcfBtePapx, (int)fib.lcbPlcfBtePapx);
    }

    // fcClx/lcbClx is pair index 33 in FibRgFcLcb97 (MS-DOC spec section 2.5.6)
    // Byte offset from FibRgFcLcb97 start: 33 * 8 = 264 = 0x0108
    // Absolute FIB offset: 0x01A2 (confirmed by spec example in section 3.1)
    if (cbRgFcLcb >= 34 && pos + 34 * 8 <= wordDocData.size()) {
        // Pair 33: fcClx (4 bytes) + lcbClx (4 bytes)
        size_t clxPairOffset = pos + 33 * 8;
        fib.fcClx = wordDocData[clxPairOffset] | (wordDocData[clxPairOffset + 1] << 8) |
                    (wordDocData[clxPairOffset + 2] << 16) | (wordDocData[clxPairOffset + 3] << 24);
        fib.lcbClx = wordDocData[clxPairOffset + 4] | (wordDocData[clxPairOffset + 5] << 8) |
                     (wordDocData[clxPairOffset + 6] << 16) | (wordDocData[clxPairOffset + 7] << 24);
        fib.valid = true;

        OH_LOG_INFO(LOG_APP, "DOC: fcClx=%{public}d, lcbClx=%{public}d", (int)fib.fcClx, (int)fib.lcbClx);
    } else {
        OH_LOG_WARN(LOG_APP, "DOC: Not enough FcLcb pairs (%{public}d, need >= 34) or FIB truncated", (int)cbRgFcLcb);
    }

    return fib;
}

/**
 * Parse the CLX (Complex part) from the Table stream to extract the Piece Table.
 *
 * CLX structure:
 *   Zero or more Prc records (type=0x01): 1 byte + 2 bytes cbGrpprl + data
 *   One Pcdt record (type=0x02): 1 byte + 4 bytes lcb + PlcPcd
 *
 * PlcPcd structure:
 *   Array of (n+1) CPs (4 bytes each)
 *   Array of n PCDs (8 bytes each)
 *   where n = (lcb - 4) / 12
 *
 * PCD (Piece Descriptor, 8 bytes):
 *   2 bytes reserved
 *   4 bytes fc (bit30=fCompressed)
 *   2 bytes prm
 */
struct TextPiece {
    uint32_t cpStart;      // Character position start
    uint32_t cpEnd;        // Character position end (exclusive)
    uint32_t byteOffset;   // Byte offset in WordDocument stream
    bool isCompressed;     // true = CP1252/ANSI (1 byte/char), false = UTF-16LE (2 bytes/char)
};

/**
 * ============================================================================
 * PAP (Paragraph Properties) Parsing - Full implementation per MS-DOC spec
 * ============================================================================
 *
 * PAP parsing is required to distinguish cell marks (0x07) from TTP marks (row end).
 * sprmPFTtp = 1 indicates a TTP mark, sprmPFTtp = 0 indicates a cell mark.
 *
 * Parsing hierarchy:
 *   FIB → fcPlcfBtePapx/lcbPlcfBtePapx → PlcBtePapx → PapxFkp → PAPX → grpprl → sprmPFTtp
 */

// Sprm structure decoder
struct SprmInfo {
    uint16_t ispmd;   // 9 bits: property modifier ID
    uint8_t fSpec;    // 1 bit: special flag
    uint8_t sgc;      // 3 bits: property group (1=paragraph)
    uint8_t spra;     // 3 bits: operand size code
    std::vector<uint8_t> operand;
};

/**
 * Parse a Sprm from grpprl data.
 * Sprm format: 2 bytes header (ispmd + fSpec + sgc + spra) + operand
 *
 * Header byte 0: bits 0-7 = ispmd low 8 bits
 * Header byte 1: bit 0 = ispmd bit 8, bit 1 = fSpec, bits 2-4 = sgc, bits 5-7 = spra
 */
static bool parseSprm(const uint8_t* grpprl, size_t grpprlSize, size_t& pos, SprmInfo& sprm) {
    if (pos + 2 > grpprlSize) return false;

    // Read 2-byte header
    uint8_t b0 = grpprl[pos];
    uint8_t b1 = grpprl[pos + 1];

    // MS-DOC spec: 16-bit Sprm in little-endian:
    // bits 0-8: ispmd, bit 9: fSpec, bits 10-12: sgc, bits 13-15: spra
    // byte1 bit layout: bit0=ispmd[8], bit1=fSpec, bits2-4=sgc, bits5-7=spra
    sprm.ispmd = b0 | ((b1 & 0x01) << 8);   // 9 bits: byte0 + byte1 bit0
    sprm.fSpec = (b1 >> 1) & 0x01;          // 1 bit: byte1 bit1
    sprm.sgc = (b1 >> 2) & 0x07;            // 3 bits: byte1 bits2-4
    sprm.spra = (b1 >> 5) & 0x07;           // 3 bits: byte1 bits5-7

    pos += 2;

    // Determine operand size based on spra (MS-DOC §2.2.5.1)
    size_t operandSize = 0;
    switch (sprm.spra) {
        case 0: operandSize = 1; break;   // 1 byte (ToggleOperand)
        case 1: operandSize = 1; break;   // 1 byte
        case 2: operandSize = 2; break;   // 2 bytes
        case 3: operandSize = 4; break;   // 4 bytes
        case 4: operandSize = 2; break;   // 2 bytes
        case 5: operandSize = 2; break;   // 2 bytes
        case 6: // Variable: first byte (cb) specifies size of remaining data
            // Operand layout: cb (1 byte) + data (cb bytes)
            // Total operand size including cb = cb + 1
            if (pos >= grpprlSize) return false;
            operandSize = grpprl[pos] + 1;  // includes the cb byte itself
            // Do NOT advance pos — operand starts at cb byte
            break;
        case 7: operandSize = 3; break;   // 3 bytes (fixed)
        default: return false;
    }

    if (pos + operandSize > grpprlSize) return false;

    sprm.operand.assign(grpprl + pos, grpprl + pos + operandSize);
    pos += operandSize;

    return true;
}

/**
 * Find sprmPFTtp in a grpprl.
 * sprmPFTtp: ispmd = 0x17 (23), fSpec = 0, sgc = 1 (paragraph)
 * Returns: -1 if not found, 0 if cell mark, 1 if TTP mark
 */
static int findSprmPFTtp(const uint8_t* grpprl, size_t grpprlSize, bool logAllSprms = false) {
    size_t pos = 0;

    OH_LOG_INFO(LOG_APP, "DOC: Parsing grpprl size=%{public}d for sprmPFTtp", (int)grpprlSize);

    // Dump first 20 bytes of grpprl for debugging
    if (grpprlSize >= 20) {
        OH_LOG_INFO(LOG_APP, "DOC: grpprl bytes[0..19]=%{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X",
                    (int)grpprl[0], (int)grpprl[1], (int)grpprl[2], (int)grpprl[3],
                    (int)grpprl[4], (int)grpprl[5], (int)grpprl[6], (int)grpprl[7],
                    (int)grpprl[8], (int)grpprl[9], (int)grpprl[10], (int)grpprl[11],
                    (int)grpprl[12], (int)grpprl[13], (int)grpprl[14], (int)grpprl[15],
                    (int)grpprl[16], (int)grpprl[17], (int)grpprl[18], (int)grpprl[19]);
    }

    while (pos < grpprlSize) {
        SprmInfo sprm;
        if (!parseSprm(grpprl, grpprlSize, pos, sprm)) {
            OH_LOG_WARN(LOG_APP, "DOC: parseSprm failed at pos=%{public}d", (int)pos);
            break;
        }

        // Log all Sprms for debugging (especially for PAPX)
        if (logAllSprms || sprm.ispmd == 0x17 || sprm.ispmd == 0x16 || sprm.ispmd == 0x49 || sprm.sgc == 5) {
            OH_LOG_INFO(LOG_APP, "DOC: PAPX Sprm: ispmd=0x%{public}X, fSpec=%{public}d, sgc=%{public}d, spra=%{public}d, operandLen=%{public}d",
                        (int)sprm.ispmd, (int)sprm.fSpec, (int)sprm.sgc, (int)sprm.spra, (int)sprm.operand.size());
            if (!sprm.operand.empty()) {
                OH_LOG_INFO(LOG_APP, "DOC: PAPX Sprm operand[0]=0x%{public}X", (int)sprm.operand[0]);
            }
        }

        // Check for sprmPFTtp: ispmd=0x17, fSpec=0, sgc=1 (paragraph property)
        // Per MS-DOC spec section 2.6.3: sprmPFTtp has sgc=1
        if (sprm.ispmd == 0x17 && sprm.fSpec == 0 && sprm.sgc == 1) {
            if (!sprm.operand.empty() && sprm.operand[0] == 1) {
                OH_LOG_INFO(LOG_APP, "DOC: FOUND sprmPFTtp=1 in PAPX! (sgc=1 paragraph)");
                return 1;  // TTP mark (row end)
            }
            OH_LOG_INFO(LOG_APP, "DOC: FOUND sprmPFTtp=0 in PAPX (cell mark, sgc=1)");
            return 0;  // Cell mark
        }
    }

    OH_LOG_INFO(LOG_APP, "DOC: sprmPFTtp not found in grpprl");
    return -1;  // Not found (default to cell mark)
}

/**
 * Parse PapxFkp (Paragraph Properties FKP) at given offset in WordDocument stream.
 * FKP is a 512-byte page.
 *
 * PapxFkp structure (per MS-DOC spec section 2.9.174):
 *   - rgfc array: (cpara+1) FC values, each 4 bytes - paragraph boundaries
 *   - rgbx array: cpara BxPap structures, each 2 bytes (bOffset + reserved)
 *   - PapxInFkp structures: located at offsets specified by rgbx.bOffset * 2
 *   - cpara: 1 byte at offset 511 (last byte of FKP)
 *
 * To find PAPX for a given FC:
 *   1. Find largest k such that rgfc[k] <= fc
 *   2. rgbx[k].bOffset * 2 = offset of PapxInFkp within FKP
 *   3. PapxInFkp contains grpprl (property list)
 */
static int findSprmPFTtpInPapxFkp(const uint8_t* fkp, uint32_t fc) {
    // FKP size is 512 bytes
    // cpara is at offset 511 (last byte)
    uint8_t cpara = fkp[511];

    OH_LOG_INFO(LOG_APP, "DOC: PapxFkp cpara=%{public}d", (int)cpara);

    if (cpara == 0 || cpara > 0x1D) {
        return -1;  // Invalid
    }

    // Read rgfc array: starts at offset 0, (cpara+1) * 4 bytes
    // rgfc[k] = FC of paragraph k's last character + 1 (exclusive)
    // We need to find largest k such that rgfc[k] <= fc
    int targetK = -1;
    for (int k = 0; k <= (int)cpara; k++) {
        uint32_t rgfc_k = fkp[k * 4] | (fkp[k * 4 + 1] << 8) |
                          (fkp[k * 4 + 2] << 16) | (fkp[k * 4 + 3] << 24);
        OH_LOG_INFO(LOG_APP, "DOC: rgfc[%{public}d]=%{public}d", k, (int)rgfc_k);

        if (rgfc_k <= fc) {
            targetK = k;
        } else {
            break;
        }
    }

    if (targetK < 0 || targetK >= (int)cpara) {
        return -1;  // No matching paragraph
    }

    OH_LOG_INFO(LOG_APP, "DOC: Found k=%{public}d for fc=%{public}d", targetK, (int)fc);

    // Read rgbx[targetK]: located after rgfc array
    // rgbx starts at offset (cpara+1) * 4
    size_t rgbxOffset = (cpara + 1) * 4;
    uint8_t bOffset = fkp[rgbxOffset + targetK * 2];

    OH_LOG_INFO(LOG_APP, "DOC: rgbx[%{public}d].bOffset=%{public}d", targetK, (int)bOffset);

    if (bOffset == 0) {
        // No PAPX for this paragraph (default properties)
        return -1;
    }

    // PapxInFkp is at offset bOffset * 2 within FKP
    size_t papxInFkpOffset = bOffset * 2;

    OH_LOG_INFO(LOG_APP, "DOC: PapxInFkp at offset %{public}d", (int)papxInFkpOffset);

    if (papxInFkpOffset >= 511) {
        return -1;  // Invalid offset
    }

    // Read PapxInFkp structure per MS-DOC spec section 2.9.175
    // PapxInFkp: cb (1 byte) + grpprlInPapx (variable)
    // If cb == 0: cb' (1 byte) + GrpPrl (2*cb' bytes) = istd (2 bytes) + grpprl (2*cb'-2 bytes)
    // If cb != 0: grpprlInPapx = GrpPrlAndIstd (2*cb-1 bytes) = istd (2 bytes) + grpprl (2*cb-3 bytes)
    uint8_t cb = fkp[papxInFkpOffset];
    size_t istdOffset;
    size_t grpprlSize;
    size_t grpprlOffset;

    // Dump first 30 bytes of PapxInFkp for debugging
    {
        char hex[256];
        int len = 0;
        size_t dumpLen = (512 - papxInFkpOffset < 40) ? (512 - papxInFkpOffset) : 40;
        for (size_t d = 0; d < dumpLen; d++) {
            len += snprintf(hex + len, sizeof(hex) - len, "%02X ", (int)fkp[papxInFkpOffset + d]);
        }
        OH_LOG_INFO(LOG_APP, "DOC: PapxInFkp raw bytes: %{public}s", hex);
    }

    if (cb == 0) {
        uint8_t cbPrime = fkp[papxInFkpOffset + 1];
        // GrpPrl is 2*cbPrime bytes: istd (2 bytes) + grpprl (2*cbPrime - 2 bytes)
        istdOffset = papxInFkpOffset + 2;
        grpprlSize = cbPrime * 2 - 2;  // Subtract 2 for istd
        grpprlOffset = papxInFkpOffset + 4;  // Skip cb, cb', and istd (2 bytes)

        OH_LOG_INFO(LOG_APP, "DOC: PapxInFkp cb=0, cb'=%{public}d, GrpPrl=%{public}d bytes, istd at %{public}d, grpprl size=%{public}d",
                    (int)cbPrime, (int)(cbPrime * 2), (int)istdOffset, (int)grpprlSize);
    } else {
        // grpprlInPapx is 2*cb-1 bytes: istd (2 bytes) + grpprl (2*cb-3 bytes)
        istdOffset = papxInFkpOffset + 1;
        grpprlSize = cb * 2 - 3;  // Total size 2*cb-1, minus istd 2 bytes
        grpprlOffset = papxInFkpOffset + 3;  // Skip cb and istd (2 bytes)

        OH_LOG_INFO(LOG_APP, "DOC: PapxInFkp cb=%{public}d, grpprlInPapx=%{public}d bytes, istd at %{public}d, grpprl size=%{public}d",
                    (int)cb, (int)(cb * 2 - 1), (int)istdOffset, (int)grpprlSize);
    }

    // Read istd (style ID) for logging
    if (istdOffset + 2 <= 512) {
        uint16_t istd = fkp[istdOffset] | (fkp[istdOffset + 1] << 8);
        OH_LOG_INFO(LOG_APP, "DOC: GrpPrlAndIstd.istd=%{public}d (style ID)", (int)istd);
    }

    if (grpprlOffset + grpprlSize > 511 || grpprlSize == 0) {
        OH_LOG_WARN(LOG_APP, "DOC: grpprl out of bounds or empty: offset=%{public}d, size=%{public}d",
                    (int)grpprlOffset, (int)grpprlSize);
        return -1;  // Invalid or empty
    }

    OH_LOG_INFO(LOG_APP, "DOC: grpprl at offset %{public}d, size %{public}d", (int)grpprlOffset, (int)grpprlSize);

    // Parse grpprl to find sprmPFTtp (with full logging)
    return findSprmPFTtp(fkp + grpprlOffset, grpprlSize, true);
}

/**
 * Parse PlcBtePapx from Table stream.
 * PlcBtePapx is a PLC that maps FC (WordDocument offsets) to Pn (page numbers).
 *
 * PLC structure: aFC array (n+1 entries, 4 bytes each) + aPn array (n entries, 4 bytes each)
 * where n = (lcb - 4) / 8
 */
struct PlcBtePapxEntry {
    uint32_t fcStart;  // FC range start
    uint32_t fcEnd;    // FC range end (exclusive, from next entry)
    uint32_t pn;       // Page number (offset = pn * 512)
};

static std::vector<PlcBtePapxEntry> parsePlcBtePapx(const uint8_t* tableData, size_t tableSize,
                                                    uint32_t fcPlcfBtePapx, uint32_t lcbPlcfBtePapx) {
    std::vector<PlcBtePapxEntry> entries;

    if (fcPlcfBtePapx + lcbPlcfBtePapx > tableSize || lcbPlcfBtePapx == 0) {
        OH_LOG_WARN(LOG_APP, "DOC: PlcBtePapx out of bounds or empty");
        return entries;
    }

    // PLC: (n+1) FC entries + n Pn entries, each 4 bytes
    // lcb = (n+1)*4 + n*4 = 8n + 4  => n = (lcb - 4) / 8
    size_t n = (lcbPlcfBtePapx - 4) / 8;

    OH_LOG_INFO(LOG_APP, "DOC: PlcBtePapx: %{public}d entries at offset %{public}d, size %{public}d",
                (int)n, (int)fcPlcfBtePapx, (int)lcbPlcfBtePapx);

    if (n == 0 || n > 10000) return entries;

    size_t pos = fcPlcfBtePapx;

    // Read FC array (n+1 entries)
    std::vector<uint32_t> fcs(n + 1);
    for (size_t i = 0; i <= n; i++) {
        fcs[i] = tableData[pos] | (tableData[pos + 1] << 8) |
                 (tableData[pos + 2] << 16) | (tableData[pos + 3] << 24);
        pos += 4;
    }

    // Read Pn array (n entries)
    for (size_t i = 0; i < n; i++) {
        uint32_t pn = tableData[pos] | (tableData[pos + 1] << 8) |
                      (tableData[pos + 2] << 16) | (tableData[pos + 3] << 24);
        pos += 4;

        PlcBtePapxEntry entry;
        entry.fcStart = fcs[i];
        entry.fcEnd = fcs[i + 1];
        entry.pn = pn;

        entries.push_back(entry);
    }

    return entries;
}

/**
 * Scan WordDocument stream for FKP (PapxInFkp) pages when PlcBtePapx is empty.
 *
 * Per MS-DOC §2.9.25 PapxInFkp:
 *   - Last byte (offset 511) = cpara (1..0x1D)
 *   - First (cpara+1)*4 bytes = rgfc: monotonically increasing FC values
 *   - At offset (cpara+1)*4: rgbx array of cpara bytes, each *2 < 511
 *
 * This is NOT a heuristic — FKP pages are a well-defined binary structure
 * specified in the MS-DOC standard. When PlcBtePapx is absent, the FKP pages
 * still exist in the WordDocument stream and contain the paragraph properties
 * (sprmPFInTable, sprmPFTtp) needed for correct table boundary detection.
 */
static std::vector<PlcBtePapxEntry> scanWordDocForFkpPages(const uint8_t* wordDocData, size_t wordDocSize) {
    std::vector<PlcBtePapxEntry> entries;

    size_t numBlocks = wordDocSize / 512;
    for (size_t blockIdx = 0; blockIdx < numBlocks; blockIdx++) {
        size_t offset = blockIdx * 512;
        if (offset + 512 > wordDocSize) break;

        const uint8_t* block = wordDocData + offset;
        uint8_t cpara = block[511];

        if (cpara < 1 || cpara > 0x1D) continue;

        // Validate rgfc: monotonically increasing FC values
        bool valid = true;
        uint32_t prev = 0;
        for (int k = 0; k <= (int)cpara; k++) {
            uint32_t fc = block[k * 4] | (block[k * 4 + 1] << 8) |
                          (block[k * 4 + 2] << 16) | (block[k * 4 + 3] << 24);
            if (k > 0 && fc <= prev) { valid = false; break; }
            prev = fc;
        }
        if (!valid) continue;

        // Validate rgbx offsets
        size_t rgbxBase = (cpara + 1) * 4;
        valid = true;
        for (int k = 0; k < (int)cpara; k++) {
            uint8_t bOffset = block[rgbxBase + k * 2];
            if (bOffset > 0 && bOffset * 2 >= 511) { valid = false; break; }
        }
        if (!valid) continue;

        // Valid FKP page found — create entry
        uint32_t firstFc = block[0] | (block[1] << 8) | (block[2] << 16) | (block[3] << 24);
        uint32_t lastFc = block[cpara * 4] | (block[cpara * 4 + 1] << 8) |
                          (block[cpara * 4 + 2] << 16) | (block[cpara * 4 + 3] << 24);

        PlcBtePapxEntry entry;
        entry.fcStart = firstFc;
        entry.fcEnd = lastFc;
        entry.pn = (uint32_t)blockIdx;
        entries.push_back(entry);
    }

    OH_LOG_INFO(LOG_APP, "DOC: Scanned WordDocument stream, found %{public}d FKP pages",
                (int)entries.size());
    return entries;
}

// ============================================================================
// LibreOffice WW8 Table Cell Structures - Ported from ww8struc.hxx
// ============================================================================

// SVBT16: little-endian 16-bit value, read as: val = bytes[0] | (bytes[1] << 8)
#define SVBT16ToUInt16(p) ((uint16_t)((p)[0] | ((p)[1] << 8)))

/**
 * WW8_TCellVer8 - TC80 structure as read from file (ww8struc.hxx:574-580)
 * Each TC80 is 20 bytes:
 *   [0..1]  aBits1Ver8 (SVBT16) - TCGRF flags
 *   [2..3]  aUnused - reserved
 *   [4..19] rgbrcVer8[4] - 4 border codes (each 4 bytes, we skip borders)
 */
struct WW8_TCellVer8 {
    uint8_t aBits1Ver8[2];   // SVBT16, little-endian
    uint8_t aUnused[2];      // reserved
    uint8_t rgbrcVer8[16];   // 4 * 4 bytes border codes (ignored for gridSpan)
};

/**
 * WW8_TCell - Working structure for cell properties (ww8struc.hxx:526-555)
 * Bit field definitions from LibreOffice:
 *   bFirstMerged : 1 (bit 0) - first cell of horizontal merge range
 *   bMerged : 1 (bit 1) - merged with preceding cell (continuation)
 *   bVertMerge : 1 (bit 5) - vertically merged with cell above
 *   bVertRestart : 1 (bit 6) - first cell of vertical merge range
 */
struct WW8_TCell {
    uint8_t bFirstMerged;   // bit 0 of aBits1Ver8
    uint8_t bMerged;        // bit 1 of aBits1Ver8
    uint8_t bVertMerge;     // bit 5 of aBits1Ver8
    uint8_t bVertRestart;   // bit 6 of aBits1Ver8
};

/**
 * TtpRowInfo - Row geometry from sprmTDefTable for gridSpan/vMerge output
 */
struct TtpRowInfo {
    std::vector<WW8_TCell> cells;      // Per-cell properties from TC80
    std::vector<uint16_t> rgdxaCenter; // n+1 column boundary entries
    uint8_t nCols = 0;
};

/**
 * Parse sprmTDefTable - Ported from WW8TabBandDesc::ReadDef (ww8par2.cxx:1079-1204)
 *
 * LibreOffice parsing logic for Ver8 (Word 97+):
 *   1. Read nCols from operand[0]
 *   2. Read n+1 rgdxaCenter entries (16-bit little-endian)
 *   3. Read n TC80 entries (20 bytes each), extract aBits1Ver8 flags
 *   4. For each TC80: bFirstMerged = (aBits1 & 0x01), bMerged = (aBits1 & 0x02)
 *   5. bVertMerge = (aBits1 & 0x20), bVertRestart = (aBits1 & 0x40)
 */
static TtpRowInfo parseTDefTableRowInfo(const std::vector<uint8_t>& operand) {
    TtpRowInfo info;

    // === LibreOffice WW8TabBandDesc::ReadDef (ww8par2.cxx:1079-1098) ===
    // Operand layout: operand[0] may have different prefix sizes
    // The actual TDefTableOperand starts at operand[0]:
    //   [0]     nCols (uint8)
    //   [1..2*(n+1)]  rgdxaCenter (n+1 entries, 2 bytes each)
    //   then TC80 array (20 bytes per cell)

    // Try different operand offsets - parseSprm may include size prefix
    size_t dataOff = 0;
    if (operand.size() >= 4 && operand[0] > 63) {
        // spra=6 prefix: operand[0] is cb (count), actual data starts at offset 1 or 2
        // Check if operand[2] is nCols (value 1-63)
        if (operand.size() >= 3 && operand[2] > 0 && operand[2] <= 63) {
            dataOff = 2;  // Our previous offset convention
        } else if (operand.size() >= 2 && operand[1] > 0 && operand[1] <= 63) {
            dataOff = 1;
        }
    }

    if (operand.size() < dataOff + 1) return info;
    uint8_t n = operand[dataOff];
    if (n == 0 || n > 63) return info;  // MAX_COL = 63

    // rgdxaCenter starts at dataOff + 1, length = (n+1) * 2
    size_t rgdxaCenterOff = dataOff + 1;
    size_t rgTc80Off = rgdxaCenterOff + (size_t)(n + 1) * 2;

    // Check if we have enough data for TC80 array
    // Each TC80 is 20 bytes (WW8_TCellVer8)
    size_t needed = rgTc80Off + (size_t)n * 20;
    if (operand.size() < needed) {
        // Partial data - still extract rgdxaCenter if available
        if (operand.size() >= rgdxaCenterOff + (n + 1) * 2) {
            info.nCols = n;
            info.rgdxaCenter.reserve(n + 1);
            for (uint8_t c = 0; c <= n; c++) {
                uint16_t xas = SVBT16ToUInt16(&operand[rgdxaCenterOff + c * 2]);
                info.rgdxaCenter.push_back(xas);
            }
        }
        return info;
    }

    info.nCols = n;

    // === Read rgdxaCenter (column boundaries) - ww8par2.cxx:1096-1098 ===
    info.rgdxaCenter.reserve(n + 1);
    for (uint8_t c = 0; c <= n; c++) {
        uint16_t xas = SVBT16ToUInt16(&operand[rgdxaCenterOff + c * 2]);
        info.rgdxaCenter.push_back(xas);
    }

    // === Read TC80 array - ww8par2.cxx:1166-1186 (Ver8 parsing) ===
    info.cells.reserve(n);
    for (uint8_t c = 0; c < n; c++) {
        // WW8_TCellVer8 starts at rgTc80Off + c * 20
        const uint8_t* pTc80 = &operand[rgTc80Off + c * 20];

        // aBits1Ver8 is SVBT16 at offset 0
        uint16_t aBits1 = SVBT16ToUInt16(pTc80);

        WW8_TCell cell;
        // LibreOffice ww8par2.cxx:1170-1176
        cell.bFirstMerged = (uint8_t)((aBits1 & 0x0001) != 0);
        cell.bMerged      = (uint8_t)((aBits1 & 0x0002) != 0);
        cell.bVertMerge   = (uint8_t)((aBits1 & 0x0020) != 0);
        cell.bVertRestart = (uint8_t)((aBits1 & 0x0040) != 0);

        info.cells.push_back(cell);
    }

    // Diagnostic: dump TC80 flags (LibreOffice format)
    {
        std::string dump;
        for (uint8_t c = 0; c < n && c < 8; c++) {
            char buf[32];
            snprintf(buf, sizeof(buf), "[%u]:FM=%d M=%d VM=%d VR=%d",
                     (unsigned)c,
                     (int)info.cells[c].bFirstMerged,
                     (int)info.cells[c].bMerged,
                     (int)info.cells[c].bVertMerge,
                     (int)info.cells[c].bVertRestart);
            if (!dump.empty()) dump += " ";
            dump += buf;
        }
        OH_LOG_INFO(LOG_APP, "DOC: TC80 LibreOffice parse n=%{public}d: %{public}s",
                    (int)n, dump.c_str());
    }

    // Diagnostic: dump rgdxaCenter
    {
        std::string dump;
        for (uint8_t c = 0; c <= n && c <= 10; c++) {
            char buf[24];
            snprintf(buf, sizeof(buf), "[%u]=%u", (unsigned)c, (unsigned)info.rgdxaCenter[c]);
            if (!dump.empty()) dump += " ";
            dump += buf;
        }
        OH_LOG_INFO(LOG_APP, "DOC: rgdxaCenter n+1=%{public}d: %{public}s",
                    (int)(n + 1), dump.c_str());
    }

    return info;
}

/**
 * Check if a given FC (WordDocument byte offset) corresponds to a TTP mark.
 * Returns: true if TTP mark (row end), false if cell mark or not in table.
 *
 * Uses FC (WordDocument byte offset) for matching with PlcBtePapx entries
 * and FKP rgfc values, which both store FC (byte offsets), not CP.
 */
static bool isTtpMark(const std::vector<PlcBtePapxEntry>& papxEntries,
                      const uint8_t* wordDocData, size_t wordDocSize,
                      uint32_t fc, uint32_t /*cp*/,
                      const uint8_t* dataStream, size_t dataStreamSize) {
    // PlcBtePapx entries store FC (byte offsets) → use fc to find the right FKP page
    // FKP rgfc values are also FC (byte offsets) → use fc for paragraph lookup within FKP
    for (const auto& entry : papxEntries) {
        if (fc >= entry.fcStart && fc < entry.fcEnd) {
            // Found the right FKP page
            uint32_t fkpOffset = entry.pn * 512;

            if (fkpOffset + 512 > wordDocSize) continue;

            const uint8_t* fkp = wordDocData + fkpOffset;

            // FKP rgfc values are FC (byte offsets), not CP — use fc for lookup
            int ttpValue = findSprmPFTtpInPapxFkp(fkp, fc);

            if (ttpValue >= 0) {
                OH_LOG_INFO(LOG_APP, "DOC: sprmPFTtp found in PapxFkp: value=%{public}d for FC=0x%{public}X", ttpValue, (int)fc);
                return (ttpValue == 1);
            }
        }
    }

    // NOTE: Do NOT use Prc from Data Stream for per-paragraph TTP detection.
    // The Prc contains DEFAULT table row properties shared by all bOffset=0 paragraphs.
    // sprmPFTtp in the Prc applies to the table context, not individual paragraphs.
    // TTP detection should fall through to text-based fallback in the caller.

    // Default: not a TTP mark (let caller use text-based fallback)
    return false;
}

/**
 * Check whether a paragraph at given FC (byte offset in WordDocument stream)
 * is inside a table.
 * Looks for sprmPFInTable (ispmd=0x16, sgc=1) — operand[0]=1 means in table.
 * Returns: 1 if in table, 0 if not in table, -1 if undetermined (no PAP info found)
 *
 * Uses FC (WordDocument byte offset) for matching with PlcBtePapx entries
 * and FKP rgfc values, which both store FC (byte offsets), not CP.
 */
static int isInTable(const std::vector<PlcBtePapxEntry>& papxEntries,
                     const uint8_t* wordDocData, size_t wordDocSize,
                     uint32_t fc) {
    for (const auto& entry : papxEntries) {
        if (fc >= entry.fcStart && fc < entry.fcEnd) {
            uint32_t fkpOffset = entry.pn * 512;
            if (fkpOffset + 512 > wordDocSize) continue;
            const uint8_t* fkp = wordDocData + fkpOffset;
            uint8_t cpara = fkp[511];
            if (cpara == 0 || cpara > 0x1D) continue;

            // Find the paragraph whose FC range contains 'fc'
            // FKP rgfc values are FC (WordDocument byte offsets), not CP
            for (int k = 0; k < (int)cpara; k++) {
                uint32_t fcStart = fkp[k * 4] | (fkp[k * 4 + 1] << 8) |
                                   (fkp[k * 4 + 2] << 16) | (fkp[k * 4 + 3] << 24);
                uint32_t fcEnd = fkp[(k + 1) * 4] | (fkp[(k + 1) * 4 + 1] << 8) |
                                 (fkp[(k + 1) * 4 + 2] << 16) | (fkp[(k + 1) * 4 + 3] << 24);
                if (fc < fcStart || fc >= fcEnd) continue;

                size_t rgbxBase = (cpara + 1) * 4;
                uint8_t bOffset = fkp[rgbxBase + k * 2];
                if (bOffset == 0) {
                    // No PAPX for this paragraph — use default (not in table)
                    return 0;
                }
                size_t papxOff = bOffset * 2;
                if (papxOff >= 511) return -1;

                uint8_t cb = fkp[papxOff];
                size_t grpprlOff, grpprlSz;
                if (cb == 0) {
                    uint8_t cbP = fkp[papxOff + 1];
                    grpprlOff = papxOff + 4;
                    grpprlSz = (size_t)cbP * 2 - 2;
                } else {
                    grpprlOff = papxOff + 3;
                    grpprlSz = (size_t)cb * 2 - 3;
                }
                if (grpprlSz == 0 || grpprlOff + grpprlSz > 511) return -1;

                size_t pos = 0;
                int result = 0;  // default: not in table
                bool foundInTable = false;
                while (pos < grpprlSz) {
                    SprmInfo sprm;
                    if (!parseSprm(fkp + grpprlOff, grpprlSz, pos, sprm)) break;
                    // sprmPFInTable: ispmd=0x16, sgc=1, spra=0
                    // operand[0]=1 → paragraph is in a table (MS-DOC §2.6.2)
                    if (sprm.ispmd == 0x16 && sprm.sgc == 1 && !sprm.operand.empty()) {
                        result = (sprm.operand[0] == 1) ? 1 : 0;
                        foundInTable = true;
                        break;
                    }
                }
                // sprmPFTtp (ispmd=0x17): TTP mark is always in-table
                if (!foundInTable) {
                    pos = 0;
                    while (pos < grpprlSz) {
                        SprmInfo sprm;
                        if (!parseSprm(fkp + grpprlOff, grpprlSz, pos, sprm)) break;
                        if (sprm.ispmd == 0x17 && sprm.sgc == 1 && !sprm.operand.empty()) {
                            if (sprm.operand[0] == 1) {
                                result = 1;
                                foundInTable = true;
                            }
                            break;
                        }
                    }
                }
                // sprmPTableProps (ispmd=0x4B, sgc=1): references Prc with table
                // formatting defaults. Only applied to table paragraphs (MS-DOC §2.6.2).
                // LibreOffice: 0x244B = sprmPTableProps
                if (!foundInTable) {
                    pos = 0;
                    while (pos < grpprlSz) {
                        SprmInfo sprm;
                        if (!parseSprm(fkp + grpprlOff, grpprlSz, pos, sprm)) break;
                        if (sprm.ispmd == 0x4B && sprm.sgc == 1) {
                            result = 1;  // sprmPTableProps → in table
                            foundInTable = true;
                            break;
                        }
                    }
                }
                // sprmTDefTable (ispmd=0x08, sgc=5): defines row cell layout,
                // only on TTP marks which are always in-table
                if (!foundInTable) {
                    pos = 0;
                    while (pos < grpprlSz) {
                        SprmInfo sprm;
                        if (!parseSprm(fkp + grpprlOff, grpprlSz, pos, sprm)) break;
                        if (sprm.ispmd == 0x08 && sprm.sgc == 5) {
                            result = 1;
                            foundInTable = true;
                            break;
                        }
                    }
                }
                // sprmPItap (ispmd=0x049, sgc=1, fSpec=1): paragraph is in a table cell
                // MS-DOC §2.6.2: Table depth is derived from sprmPFInTable, sprmPItap,
                // and sprmPDtap. Paragraphs with sprmPItap are always in-table.
                if (!foundInTable) {
                    pos = 0;
                    while (pos < grpprlSz) {
                        SprmInfo sprm;
                        if (!parseSprm(fkp + grpprlOff, grpprlSz, pos, sprm)) break;
                        if (sprm.ispmd == 0x049 && sprm.sgc == 1 && sprm.fSpec == 1) {
                            result = 1;
                            foundInTable = true;
                            break;
                        }
                    }
                }
                return foundInTable ? result : 0;
            }
            // No matching paragraph in FKP — likely not in table
            return 0;
        }
    }
    return -1;  // No PAP info
}

/**
 * Data structures for LibreOffice-style table region detection.
 * A TableRegion represents a contiguous range of table content in the
 * WordDocument stream, with FC boundaries for each row.
 */
struct RowInfo {
    uint32_t firstCellFc;   // FC of first cell content in this row
    uint32_t lastCellFc;    // FC of last cell/TTP in this row
    uint32_t ttpFcEnd;      // rgfc[k+1] of TTP paragraph (map key for ttpRowInfoMap)
};

struct TableRegion {
    uint32_t startFc;       // FC of first content in table
    uint32_t endFc;         // FC of last content in table
    std::vector<RowInfo> rows;
};

/**
 * Collect all paragraphs from FKPs, sorted by FC.
 * Each entry: (fcStart, fcEnd) from the FKP rgfc array.
 */
struct ParagraphRange {
    uint32_t fcStart;
    uint32_t fcEnd;
};

static std::vector<ParagraphRange> collectAllParagraphs(
    const std::vector<PlcBtePapxEntry>& papxEntries,
    const uint8_t* wordDocData, size_t wordDocSize)
{
    std::vector<ParagraphRange> paragraphs;
    for (const auto& entry : papxEntries) {
        uint32_t fkpOffset = entry.pn * 512;
        if (fkpOffset + 512 > wordDocSize) continue;
        const uint8_t* fkp = wordDocData + fkpOffset;
        uint8_t cpara = fkp[511];
        if (cpara == 0 || cpara > 0x1D) continue;

        for (int k = 0; k < (int)cpara; k++) {
            uint32_t fcStart = fkp[k * 4] | (fkp[k * 4 + 1] << 8) |
                               (fkp[k * 4 + 2] << 16) | (fkp[k * 4 + 3] << 24);
            uint32_t fcEnd = fkp[(k + 1) * 4] | (fkp[(k + 1) * 4 + 1] << 8) |
                             (fkp[(k + 1) * 4 + 2] << 16) | (fkp[(k + 1) * 4 + 3] << 24);
            paragraphs.push_back({fcStart, fcEnd});
        }
    }
    // Sort by fcStart, deduplicate
    std::sort(paragraphs.begin(), paragraphs.end(),
              [](const ParagraphRange& a, const ParagraphRange& b) {
                  return a.fcStart < b.fcStart;
              });
    paragraphs.erase(std::unique(paragraphs.begin(), paragraphs.end(),
                                 [](const ParagraphRange& a, const ParagraphRange& b) {
                                     return a.fcStart == b.fcStart && a.fcEnd == b.fcEnd;
                                 }),
                     paragraphs.end());
    return paragraphs;
}

/**
 * LibreOffice-style sequential table scan.
 *
 * LibreOffice's algorithm (WW8TabDesc):
 * 1. Walk paragraphs sequentially in FC order
 * 2. For each paragraph, check HasTabCellSprm (sprmPFInTable)
 * 3. If in table, scan forward to find row end (TTP mark)
 * 4. After TTP, check if next paragraph is still in table
 * 5. If not, table ends
 *
 * Key difference from naive approach: LibreOffice checks table membership
 * ONLY on row-start paragraphs (the first paragraph of each row, which has
 * sprmPFInTable=1 in its PAPX). The bOffset=0 content paragraphs between
 * \x07 marks do NOT need to pass isInTable() — they are implicitly in the
 * table because they fall within the row's FC range (rowStart → TTP).
 *
 * This function accepts pre-scanned rowStarts and ttpRowInfoMap so it can
 * correctly handle both:
 * - Tables with explicit TTP marks (sprmPFTtp in PAPX)
 * - Tables with implicit TTP (via Prc-referenced sprmTDefTable)
 * - Tables where row-start paragraphs have bOffset=0 content between them
 */
struct RowStartInfo { uint32_t fcStart; uint32_t fcEnd; };

/**
 * Complete implementation of LibreOffice's table parsing logic.
 * Directly translates ww8par.cxx ProcessSpecial and ww8par2.cxx WW8TabDesc.
 *
 * Key LibreOffice functions:
 * - ProcessSpecial (ww8par.cxx:2718-2810): nCellLevel calculation, bStartTab/bStopTab
 * - WW8TabDesc (ww8par2.cxx:1880-2078): table row processing loop
 * - HasTabCellSprm (ww8par2.cxx:1590-1600): checks sprmPFInTable existence
 * - SearchRowEnd (ww8par2.cxx:340-392): finds sprmPFTtp=1
 *
 * Core logic flow:
 * 1. For each paragraph in CP order:
 *    nCellLevel = HasTabCellSprm(pPap) ? 1 : 0
 *    bStartTab = (m_nInTable < nCellLevel)
 *    bStopTab = m_bWasTabRowEnd && (m_nInTable > nCellLevel)
 *
 * 2. When bStartTab: enter WW8TabDesc loop
 *    - SearchRowEnd to find TTP
 *    - After TTP, SeekPos to next CP
 *    - GetSprms to get SPRMs at that position
 *    - If HasTabCellSprm returns nullptr or value!=1, break
 *
 * 3. When bStopTab: table ends, m_nInTable = 0
 *
 * PLCF iterator simulation:
 * - Maintains "current effective PAPX" with CP range [start, end)
 * - For paragraphs within the range, inherit SPRMs
 * - When paragraph CP exceeds range, find new effective PAPX
 */
static std::vector<TableRegion> scanTablesSequential(
    const std::vector<PlcBtePapxEntry>& papxEntries,
    const uint8_t* wordDocData, size_t wordDocSize,
    const std::map<uint32_t, TtpRowInfo>& ttpRowInfoMap,
    const std::vector<RowStartInfo>& rowStarts,
    const uint8_t* dataStream, size_t dataStreamSize)
{
    std::vector<TableRegion> regions;

    // -----------------------------------------------------------------------
    // Simulate LibreOffice's PLCF iterator for PAP (WW8PLCFx_Cp_FKP)
    //
    // The iterator maintains:
    // - Current CP position
    // - Current effective PAPX (from FKP with its CP range)
    // - When moving to a new CP outside current range, find new PAPX
    //
    // HasParaSprm(sprmId): checks if SPRM exists in current effective PAPX
    // GetSprms(): returns current effective PAPX's grpprl
    // -----------------------------------------------------------------------

    // Build map of CP ranges to PAPX content
    // CP is character position in the document stream
    // But our segments use FC (byte offset). We need to work with FC.

    // Key insight: LibreOffice works with CP, but FC is the byte offset.
    // PlcBtePapx stores FC ranges. FKP rgfc stores FC.
    // We'll work with FC directly (like LibreOffice does internally for FKP).

    // Collect all FKP pages and their PAPX entries with FC ranges
    struct PapxEntry {
        uint32_t fcStart;     // rgfc[k] - paragraph FC start
        uint32_t fcEnd;       // rgfc[k+1] - paragraph FC end
        uint8_t bOffset;      // bOffset from rgbx
        int fkpIndex;         // index in FKP
        int papxIndex;        // k index in FKP
    };
    std::vector<PapxEntry> papxList;

    for (const auto& entry : papxEntries) {
        uint32_t fkpOffset = entry.pn * 512;
        if (fkpOffset + 512 > wordDocSize) continue;
        const uint8_t* fkp = wordDocData + fkpOffset;
        uint8_t cpara = fkp[511];
        if (cpara == 0 || cpara > 0x1D) continue;

        size_t rgbxBase = (cpara + 1) * 4;
        for (int k = 0; k < (int)cpara; k++) {
            uint32_t fcStart = fkp[k * 4] | (fkp[k * 4 + 1] << 8) |
                               (fkp[k * 4 + 2] << 16) | (fkp[k * 4 + 3] << 24);
            uint32_t fcEnd = fkp[(k + 1) * 4] | (fkp[(k + 1) * 4 + 1] << 8) |
                             (fkp[(k + 1) * 4 + 2] << 16) | (fkp[(k + 1) * 4 + 3] << 24);
            uint8_t bOffset = fkp[rgbxBase + k * 2];
            papxList.push_back({fcStart, fcEnd, bOffset, (int)entry.pn, k});
        }
    }
    // Sort by FC start
    std::sort(papxList.begin(), papxList.end(),
              [](const PapxEntry& a, const PapxEntry& b) { return a.fcStart < b.fcStart; });

    OH_LOG_INFO(LOG_APP, "DOC: PLCF simulation: %{public}d PAPX entries", (int)papxList.size());

    // -----------------------------------------------------------------------
    // Helper: Find PAPX entry covering a given FC
    // Returns nullptr if FC is beyond all ranges (inherit last)
    // -----------------------------------------------------------------------
    auto findPapxByFc = [&](uint32_t fc) -> const PapxEntry* {
        for (const auto& pe : papxList) {
            if (fc >= pe.fcStart && fc < pe.fcEnd) {
                return &pe;
            }
        }
        // FC is outside all ranges - return nullptr (use last known state)
        return nullptr;
    };

    // -----------------------------------------------------------------------
    // Helper: Check if SPRM exists in PAPX grpprl
    // Returns true if found, and optionally returns value
    // Implements HasParaSprm from LibreOffice
    // -----------------------------------------------------------------------
    auto hasSprm = [&](const PapxEntry* pe, uint16_t sprmId, uint8_t* pValue = nullptr) -> bool {
        if (!pe || pe->bOffset == 0) {
            // bOffset=0: no PAPX, inherit (handled by caller)
            return false;
        }

        uint32_t fkpOffset = pe->fkpIndex * 512;
        if (fkpOffset + 512 > wordDocSize) return false;
        const uint8_t* fkp = wordDocData + fkpOffset;

        size_t papxOff = pe->bOffset * 2;
        if (papxOff >= 511) return false;

        uint8_t cb = fkp[papxOff];
        size_t grpprlOff, grpprlSz;
        if (cb == 0) {
            if (papxOff + 1 >= 511) return false;
            uint8_t cbP = fkp[papxOff + 1];
            grpprlOff = papxOff + 4;
            grpprlSz = cbP * 2 - 2;
        } else {
            grpprlOff = papxOff + 3;
            grpprlSz = cb * 2 - 3;
        }
        if (grpprlSz == 0 || grpprlOff + grpprlSz > 511) return false;

        size_t pos = 0;
        while (pos < grpprlSz) {
            SprmInfo sprm;
            if (!parseSprm(fkp + grpprlOff, grpprlSz, pos, sprm)) break;
            // LibreOffice HasSprm encoding (ww8par.cxx):
            // sprmId 16-bit: bits 0-8=ispmd, bit 9=fSpec, bits 10-12=sgc, bits 13-15=spra
            // Example: sprmPFInTable (0x2416) → ispmd=0x16, fSpec=0, sgc=1, spra=4
            // Decode: ispmd = sprmId & 0x1FF, sgc = (sprmId >> 10) & 0x07
            uint16_t expectedIspmd = sprmId & 0x1FF;  // 9 bits
            uint16_t expectedSgc = (sprmId >> 10) & 0x07;  // bits 10-12
            if (sprm.ispmd == expectedIspmd && sprm.sgc == expectedSgc) {
                if (pValue && !sprm.operand.empty()) {
                    *pValue = sprm.operand[0];
                }
                return true;
            }
        }
        return false;
    };

    // -----------------------------------------------------------------------
    // LibreOffice's HasTabCellSprm (ww8par2.cxx:1590-1600)
    // ww8par.cxx:2763: nCellLevel = int(nullptr != HasParaSprm(0x2416).pSprm)
    // ww8par2.cxx:2018-2028: Checks SPRM VALUE is 1, not just presence
    // Key: HasTabCellSprm returns SprmResult with pSprm and operand value
    // Table continues only if value == 1
    // -----------------------------------------------------------------------
    auto computeCellLevel = [&](const PapxEntry* pe) -> int {
        // LibreOffice: check sprmPFInTable (0x2416) presence AND value
        // Returns 1 if SPRM exists AND operand[0] == 1
        if (!pe || pe->bOffset == 0) {
            // bOffset=0: no explicit PAPX in FKP
            // ww8par2.cxx:2018-2028: No HasTabCellSprm → break (table ends)
            return 0;
        }

        // ww8par2.cxx:1596-1598: Check sprmPFInnerTableCell first, then sprmPFInTable
        // Check sprmPFInTable (ispmd=0x16, sgc=1) - ww8par2.cxx:2024: (1 != *pParams)
        uint8_t value = 0;
        if (hasSprm(pe, 0x2416, &value) && value == 1) {
            return 1;
        }

        // Check sprmPFInnerTableCell (ispmd=0x4B, sgc=1) - ww8par2.cxx:1596
        if (hasSprm(pe, 0x244B, &value) && value == 1) {
            return 1;
        }

        return 0;
    };

    auto hasTabCellSprm = [&](uint32_t fc) -> int {
        const PapxEntry* pe = findPapxByFc(fc);

        // LibreOffice's PLCF approach: check explicit PAPX at this position
        // No inheritance from previous explicit state
        return computeCellLevel(pe);
    };

    // Build set of TTP FC ends for quick lookup (used by searchRowEnd)
    std::set<uint32_t> ttpFcEndSet;
    for (const auto& [fcEnd, _] : ttpRowInfoMap) {
        ttpFcEndSet.insert(fcEnd);
    }

    // -----------------------------------------------------------------------
    // LibreOffice's SearchRowEnd (ww8par2.cxx:340-392)
    // Scans forward from start FC to find sprmPFTtp=1 (TTP mark)
    // Also checks ttpFcEndSet for TTP detected via sprmTDefTable
    // -----------------------------------------------------------------------
    auto searchRowEnd = [&](uint32_t startFc) -> const PapxEntry* {
        for (const auto& pe : papxList) {
            if (pe.fcStart < startFc) continue;

            // Check if fcEnd is in TTP set (detected via sprmTDefTable)
            if (ttpFcEndSet.find(pe.fcEnd) != ttpFcEndSet.end()) {
                return &pe;
            }

            // Check if this is TTP (sprmPFTtp=1)
            uint8_t ttpValue = 0;
            if (pe.bOffset != 0 && hasSprm(&pe, 0x2417, &ttpValue) && ttpValue == 1) {
                return &pe;
            }
        }
        return nullptr;  // No TTP found
    };

    // -----------------------------------------------------------------------
    // Main loop: ProcessSpecial-style iteration
    // Strictly following ww8par.cxx:2757-2879
    // -----------------------------------------------------------------------
    int m_nInTable = 0;        // Current table nesting level
    bool m_bWasTabRowEnd = false;  // Previous paragraph was TTP

    size_t pi = 0;
    OH_LOG_INFO(LOG_APP, "DOC: Starting main loop with %{public}d PAPX entries", (int)papxList.size());
    while (pi < papxList.size()) {
        const auto& pe = papxList[pi];
        uint32_t fc = pe.fcStart;

        // ww8par.cxx:2757-2763: compute nCellLevel from sprmPFInTable (0x2416)
        int nCellLevel = hasTabCellSprm(fc);

        // ww8par.cxx:2800: bStartTab = (m_nInTable < nCellLevel)
        bool bStartTab = (m_nInTable < nCellLevel);

        // ww8par.cxx:2802: bStopTab = m_bWasTabRowEnd && (m_nInTable > nCellLevel)
        bool bStopTab = m_bWasTabRowEnd && (m_nInTable > nCellLevel);

        // ww8par.cxx:2804: m_bWasTabRowEnd must be deactivated right here
        m_bWasTabRowEnd = false;

        // ww8par.cxx:2834-2838: if bStopTab, call StopTable() and decrement
        if (bStopTab) {
            // StopTable() equivalent - table ends
            --m_nInTable;
            OH_LOG_INFO(LOG_APP, "DOC: bStopTab at PAPX[%{public}d] FC=%{public}d, m_nInTable=%{public}d -> %{public}d",
                        (int)pi, (int)fc, m_nInTable + 1, m_nInTable);
            if (m_nInTable < 0) m_nInTable = 0;  // Safety
        }

        // ww8par.cxx:2862-2867: if bStartTab, call StartTable() and increment
        if (bStartTab) {
            // StartTable() equivalent - new table starts
            ++m_nInTable;
            OH_LOG_INFO(LOG_APP, "DOC: bStartTab at PAPX[%{public}d] FC=%{public}d, m_nInTable=%{public}d",
                        (int)pi, (int)fc, m_nInTable);
        }

        // ww8par.cxx:2879: do-while loop continues if m_nInTable < nCellLevel
        if (m_nInTable < nCellLevel) {
            // Still need to process higher nesting level
            pi++;
            continue;
        }

        if (m_nInTable == 0) {
            // Not in table - skip
            OH_LOG_INFO(LOG_APP, "DOC: Skip PAPX[%{public}d] FC=%{public}d (not in table)",
                        (int)pi, (int)fc);
            pi++;
            continue;
        }

        // ---------------------------------------------------------------
        // WW8TabDesc constructor starts here
        // Process rows until HasTabCellSprm returns nullptr or value!=1
        // ---------------------------------------------------------------
        OH_LOG_INFO(LOG_APP, "DOC: Table start at FC=%{public}d (PAPX[%{public}d])",
                    (int)fc, (int)pi);

        TableRegion region;
        region.startFc = fc;

        size_t rowPi = pi;
        while (rowPi < papxList.size()) {
            // SearchRowEnd: find TTP for this row
            const PapxEntry* ttpPe = searchRowEnd(papxList[rowPi].fcStart);
            if (!ttpPe) {
                // No TTP found - try ttpRowInfoMap
                uint32_t rowFcEnd = papxList[rowPi].fcEnd;
                bool foundInMap = false;
                for (uint32_t ttpFc : ttpFcEndSet) {
                    if (ttpFc >= papxList[rowPi].fcStart && ttpFc <= rowFcEnd + 10) {
                        foundInMap = true;
                        // Find the PAPX for this TTP
                        for (size_t ti = rowPi; ti < papxList.size(); ti++) {
                            if (papxList[ti].fcEnd == ttpFc || papxList[ti].fcEnd == ttpFc + 1 ||
                                papxList[ti].fcEnd + 1 == ttpFc) {
                                ttpPe = &papxList[ti];
                                break;
                            }
                        }
                        break;
                    }
                }
                if (!foundInMap) {
                    OH_LOG_INFO(LOG_APP, "DOC: No TTP found for row at FC=%{public}d",
                                (int)papxList[rowPi].fcStart);
                    break;
                }
            }

            if (!ttpPe) {
                break;
            }

            // Record the row
            RowInfo ri;
            ri.firstCellFc = papxList[rowPi].fcStart;
            ri.lastCellFc = ttpPe->fcStart;
            ri.ttpFcEnd = ttpPe->fcEnd;
            region.rows.push_back(ri);

            OH_LOG_INFO(LOG_APP, "DOC: Row: FC=[%{public}d,%{public}d] TTP_end=%{public}d",
                        (int)ri.firstCellFc, (int)ri.lastCellFc, (int)ri.ttpFcEnd);

            // ww8par.cxx:2729: bTableRowEnd marks TTP paragraph
            // ww8par.cxx:2802: bStopTab uses m_bWasTabRowEnd from previous iteration
            // Set m_bWasTabRowEnd = true so next main loop iteration can check bStopTab
            m_bWasTabRowEnd = true;

            // -----------------------------------------------------------------------
            // LibreOffice's ProcessSpecial (ww8par.cxx:2800-2879)
            // After TTP mark, check next paragraph's nCellLevel
            // bStopTab = m_bWasTabRowEnd && (m_nInTable > nCellLevel)
            // No FC gap threshold - pure nCellLevel comparison
            // -----------------------------------------------------------------------
            size_t nextPi = rowPi + 1;
            while (nextPi < papxList.size() && papxList[nextPi].fcStart <= ttpPe->fcEnd) {
                nextPi++;  // Skip paragraphs within TTP FC range
            }

            if (nextPi >= papxList.size()) {
                // End of document - table ends naturally
                OH_LOG_INFO(LOG_APP, "DOC: Table ends (end of document)");
                break;
            }

            // ww8par.cxx:2757-2763: compute nCellLevel from HasParaSprm(0x2416)
            int nextCellLevel = hasTabCellSprm(papxList[nextPi].fcStart);

            OH_LOG_INFO(LOG_APP, "DOC: After TTP, PAPX[%{public}d] FC=%{public}d m_nInTable=%{public}d nextCellLevel=%{public}d",
                        (int)nextPi, (int)papxList[nextPi].fcStart, m_nInTable, nextCellLevel);

            // ww8par.cxx:2802: bStopTab = m_bWasTabRowEnd && (m_nInTable > nCellLevel)
            // m_bWasTabRowEnd is already true from above
            // This is the KEY table boundary detection logic
            if (m_nInTable > nextCellLevel) {
                // Table ends when nesting level decreases after TTP
                OH_LOG_INFO(LOG_APP, "DOC: Table ends (bStopTab: m_nInTable=%{public}d > nextCellLevel=%{public}d)",
                            m_nInTable, nextCellLevel);
                break;
            }

            // Continue with same table - reset m_bWasTabRowEnd for next iteration
            m_bWasTabRowEnd = false;
            rowPi = nextPi;
        }

        if (!region.rows.empty()) {
            region.endFc = region.rows.back().lastCellFc;
            regions.push_back(std::move(region));
        }

        // Move to next PAPX
        pi = rowPi + 1;
    }

    OH_LOG_INFO(LOG_APP, "DOC: LibreOffice table scan: %{public}d tables detected",
                (int)regions.size());
    for (size_t ti = 0; ti < regions.size(); ti++) {
        OH_LOG_INFO(LOG_APP, "DOC: Table[%{public}d]: %{public}d rows, FC [%{public}d, %{public}d]",
                    (int)ti, (int)regions[ti].rows.size(),
                    (int)regions[ti].startFc, (int)regions[ti].endFc);
    }

    return regions;
}

static std::vector<TextPiece> parsePieceTable(const uint8_t* tableData, size_t tableSize,
                                               uint32_t fcClx, uint32_t lcbClx) {
    std::vector<TextPiece> pieces;

    if (fcClx + lcbClx > tableSize || lcbClx == 0) {
        OH_LOG_ERROR(LOG_APP, "DOC: CLX out of bounds: fcClx=%{public}d, lcbClx=%{public}d, tableSize=%{public}d",
                     (int)fcClx, (int)lcbClx, (int)tableSize);
        return pieces;
    }

    size_t pos = fcClx;
    size_t end = fcClx + lcbClx;

    // Skip Prc records (type 0x01)
    while (pos < end) {
        uint8_t clxType = tableData[pos];
        if (clxType == 0x01) {
            // Prc: skip cbGrpprl bytes of data
            pos++;
            if (pos + 2 > end) break;
            uint16_t cbGrpprl = tableData[pos] | (tableData[pos + 1] << 8);
            pos += 2 + cbGrpprl;
        } else if (clxType == 0x02) {
            // Pcdt found
            pos++;
            break;
        } else {
            OH_LOG_WARN(LOG_APP, "DOC: Unknown CLX entry type 0x%{public}02X at pos %{public}d", clxType, (int)pos);
            pos++;
        }
    }

    if (pos + 4 > end) {
        OH_LOG_ERROR(LOG_APP, "DOC: CLX Pcdt header truncated");
        return pieces;
    }

    // Read lcb (size of PlcPcd)
    uint32_t lcbPlcPcd = tableData[pos] | (tableData[pos + 1] << 8) |
                         (tableData[pos + 2] << 16) | (tableData[pos + 3] << 24);
    pos += 4;

    OH_LOG_INFO(LOG_APP, "DOC: PlcPcd lcb=%{public}d", (int)lcbPlcPcd);

    if (lcbPlcPcd < 4 + 8) {
        OH_LOG_ERROR(LOG_APP, "DOC: PlcPcd too small: %{public}d", (int)lcbPlcPcd);
        return pieces;
    }

    // Calculate number of pieces
    // lcb = (n+1) * 4 + n * 8 = 12n + 4  =>  n = (lcb - 4) / 12
    uint32_t n = (lcbPlcPcd - 4) / 12;

    OH_LOG_INFO(LOG_APP, "DOC: Number of text pieces: %{public}d", (int)n);

    if (n == 0 || n > 100000) {
        OH_LOG_ERROR(LOG_APP, "DOC: Invalid piece count: %{public}d", (int)n);
        return pieces;
    }

    // Verify we have enough data
    size_t cpArraySize = (n + 1) * 4;
    size_t pcdArraySize = n * 8;
    if (pos + cpArraySize + pcdArraySize > end) {
        OH_LOG_ERROR(LOG_APP, "DOC: PlcPcd data truncated, need %{public}d bytes", (int)(cpArraySize + pcdArraySize));
        return pieces;
    }

    // Read CP array (n+1 entries, each 4 bytes)
    std::vector<uint32_t> cps(n + 1);
    for (uint32_t i = 0; i <= n; i++) {
        size_t cpPos = pos + i * 4;
        cps[i] = tableData[cpPos] | (tableData[cpPos + 1] << 8) |
                 (tableData[cpPos + 2] << 16) | (tableData[cpPos + 3] << 24);
    }

    // Read PCD array (n entries, each 8 bytes) - starts after CP array
    size_t pcdStart = pos + cpArraySize;
    for (uint32_t i = 0; i < n; i++) {
        size_t pcdPos = pcdStart + i * 8;

        // Skip 2 bytes reserved
        // Read fc (4 bytes at offset 2 in PCD)
        uint32_t fc = tableData[pcdPos + 2] | (tableData[pcdPos + 3] << 8) |
                      (tableData[pcdPos + 4] << 16) | (tableData[pcdPos + 5] << 24);

        // fCompressed is bit 30 of fc
        bool fCompressed = (fc & 0x40000000) != 0;

        // Calculate byte offset in WordDocument stream
        uint32_t byteOffset;
        if (fCompressed) {
            // Compressed: byte offset = (fc & 0x3FFFFFFF) / 2
            byteOffset = (fc & 0x3FFFFFFF) / 2;
        } else {
            // Uncompressed: byte offset = fc directly
            byteOffset = fc;
        }

        TextPiece piece;
        piece.cpStart = cps[i];
        piece.cpEnd = cps[i + 1];
        piece.byteOffset = byteOffset;
        piece.isCompressed = fCompressed;

        OH_LOG_INFO(LOG_APP, "DOC: Piece %{public}d: CP[%{public}d..%{public}d], fc=0x%{public}08X, "
                    "byteOffset=%{public}d, compressed=%{public}d, chars=%{public}d",
                    (int)i, (int)piece.cpStart, (int)piece.cpEnd, fc,
                    (int)piece.byteOffset, (int)piece.isCompressed, (int)(piece.cpEnd - piece.cpStart));

        pieces.push_back(piece);
    }

    return pieces;
}

// ============================================================================
// DOC Content Elements - structured representation for DOCX generation
// ============================================================================

enum class DocElementType { PARAGRAPH, TABLE, IMAGE_PLACEHOLDER };

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

struct DocTableRow {
    std::vector<DocTableCell> cells;
};

struct DocTable {
    std::vector<DocTableRow> rows;
};

struct DocContentElement {
    DocElementType type;
    std::string text;                    // For PARAGRAPH
    DocTable table;                      // For TABLE
    int imageIndex = -1;                 // For IMAGE_PLACEHOLDER
};

/**
 * Trim trailing whitespace from a string
 */
static std::string trimTrailing(const std::string& s) {
    size_t end = s.size();
    while (end > 0 && (s[end - 1] == ' ' || s[end - 1] == '\t')) {
        end--;
    }
    return s.substr(0, end);
}

/**
 * Extract structured content from the WordDocument stream using the piece table.
 * Returns a mix of paragraphs, tables, and image placeholders.
 *
 * Table detection heuristic:
 * Table detection via PAP parsing:
 * - Parse PlcBtePapx to find paragraph properties for each FC
 * - In grpprl, find sprmPFTtp to distinguish cell marks from TTP marks
 * - TTP mark (sprmPFTtp=1) = row end, cell mark (sprmPFTtp=0) = cell separator
 */
static std::vector<DocContentElement> extractDocContent(
    const std::vector<uint8_t>& wordDocData,
    const std::vector<uint8_t>& tableData,
    const std::vector<uint8_t>& dataStream,
    const FibParseResult& fib,
    const std::vector<TextPiece>& pieces)
{
    std::vector<DocContentElement> elements;

    // Parse PlcBtePapx for PAP data (if available)
    std::vector<PlcBtePapxEntry> papxEntries;
    if (fib.fcPlcfBtePapx > 0 && fib.lcbPlcfBtePapx > 0) {
        papxEntries = parsePlcBtePapx(tableData.data(), tableData.size(),
                                      fib.fcPlcfBtePapx, fib.lcbPlcfBtePapx);
        OH_LOG_INFO(LOG_APP, "DOC: Parsed %{public}d PlcBtePapx entries for PAP", (int)papxEntries.size());
    }

    // When PlcBtePapx is empty, scan WordDocument stream for FKP pages directly.
    // Per MS-DOC §2.9.25, FKP (PapxInFkp) pages are embedded in the WordDocument
    // stream and contain paragraph properties (sprmPFInTable, sprmPFTtp).
    // This is the standard-defined fallback, not a heuristic.
    if (papxEntries.empty()) {
        papxEntries = scanWordDocForFkpPages(wordDocData.data(), wordDocData.size());
    }

    // First pass: decode all text and track CP (Character Position) and FC positions
    struct TextSegment {
        std::string text;
        char delimiter;      // '\r', '\x07', '\x0B', '\x0C', '\0' (end)
        uint32_t fcPosition; // FC (WordDocument byte offset) where delimiter was found
        uint32_t cpPosition; // CP (Character Position) — logical index for PAP matching
    };
    std::vector<TextSegment> segments;

    std::string currentText;
    uint32_t currentFc = 0;  // Track FC position in WordDocument stream

    for (const auto& piece : pieces) {
        uint32_t charCount = piece.cpEnd - piece.cpStart;
        if (charCount == 0) continue;

        // Calculate FC range for this piece
        uint32_t pieceFcStart = piece.byteOffset;
        uint32_t pieceFcEnd = piece.isCompressed ? piece.byteOffset + charCount : piece.byteOffset + charCount * 2;
        uint32_t pieceCpStart = piece.cpStart;

        std::string pieceText;
        if (piece.isCompressed) {
            if (piece.byteOffset + charCount <= wordDocData.size()) {
                pieceText = decodeCP1252toUTF8(wordDocData.data(), piece.byteOffset, charCount);
            }
        } else {
            uint32_t byteCount = charCount * 2;
            if (piece.byteOffset + byteCount <= wordDocData.size()) {
                pieceText = decodeUTF16LEtoUTF8(wordDocData.data(), piece.byteOffset, charCount);
            }
        }

        // Track position within piece
        size_t charIdx = 0;
        size_t byteIdx = 0;
        while (byteIdx < pieceText.size()) {
            unsigned char firstByte = (unsigned char)pieceText[byteIdx];

            // Determine UTF-8 character length (1-4 bytes)
            int charLen = 1;
            if ((firstByte & 0x80) != 0) {
                if ((firstByte & 0xE0) == 0xC0) charLen = 2;
                else if ((firstByte & 0xF0) == 0xE0) charLen = 3;
                else if ((firstByte & 0xF8) == 0xF0) charLen = 4;
            }

            if (byteIdx + charLen > pieceText.size()) break;

            // Calculate FC and CP for this character (once per Unicode character, not per byte)
            uint32_t charFc = piece.isCompressed ? pieceFcStart + charIdx : pieceFcStart + charIdx * 2;
            uint32_t charCp = pieceCpStart + (uint32_t)charIdx;
            charIdx++;

            // Delimiters are all ASCII (single-byte), use firstByte for comparison
            if (firstByte == '\r' || firstByte == '\x07' || firstByte == '\x0B' || firstByte == '\x0C') {
                std::string trimmed = trimTrailing(currentText);
                if (!trimmed.empty() || firstByte == '\x07' || firstByte == '\r') {
                    segments.push_back({trimmed, (char)firstByte, charFc, charCp});
                }
                currentText.clear();
            } else if (firstByte == '\n') {
                currentText += ' ';
            } else if (firstByte == '\x01') {
                currentText += "\x01";
            } else if (firstByte != '\0') {
                // Append the full multi-byte UTF-8 character
                currentText.append(pieceText, byteIdx, charLen);
            }

            byteIdx += charLen;
        }

        currentFc = pieceFcEnd;
    }

    // Handle last segment
    {
        std::string trimmed = trimTrailing(currentText);
        if (!trimmed.empty()) {
            segments.push_back({trimmed, '\0'});
        }
    }

    // Log segment analysis for debugging
    int cellMarkCount = 0, paraMarkCount = 0;
    for (const auto& seg : segments) {
        if (seg.delimiter == '\x07') cellMarkCount++;
        else if (seg.delimiter == '\r') paraMarkCount++;
    }
    OH_LOG_INFO(LOG_APP, "DOC: Segment analysis: %{public}d total, %{public}d cell marks (0x07), %{public}d para marks (\\r)",
                (int)segments.size(), cellMarkCount, paraMarkCount);

    // Find correct Prc by scanning ALL PapxInFkp entries for sprmPTableProps (ispmd=0x4B)
    // Multiple Prc offsets may exist — we need the one with sprmTDefTable
    int globalColumnCount = 0;
    std::vector<uint32_t> prcOffsets;
    // Per-TTP row geometry (declared at file scope as TtpRowInfo).
    // Keyed by rgfc[k+1] from FKP — the FC AFTER the paragraph delimiter.
    std::map<uint32_t, TtpRowInfo> ttpRowInfoMap;
    // Map from TTP FC end → list of (itcFirst, itcLim) merge ranges from sprmTMerge.
    // Each range marks cells [itcFirst, itcLim) as horizontally merged.
    struct MergeRange { uint8_t itcFirst; uint8_t itcLim; };
    std::map<uint32_t, std::vector<MergeRange>> ttpMergeRangesMap;

    // Map of FC ranges for paragraphs that have sprmPFInTable=1 but NOT sprmPFTtp.
    // These are "row-start" markers for tables where TTP marks lack inline PAPX
    // (bOffset=0). Used as a fallback for row splitting when ttpRowInfoMap is empty.
    std::vector<RowStartInfo> rowStarts;

    // Step 1: Collect ALL sprmPTableProps offsets from all PapxInFkp entries
    for (const auto& entry : papxEntries) {
        uint32_t fkpOffset = entry.pn * 512;
        if (fkpOffset + 512 > wordDocData.size()) continue;
        const uint8_t* fkp = wordDocData.data() + fkpOffset;
        uint8_t cpara = fkp[511];
        if (cpara == 0 || cpara > 0x1D) continue;

        size_t rgbxBase = (cpara + 1) * 4;
        for (int k = 0; k < (int)cpara; k++) {
            uint8_t bOffset = fkp[rgbxBase + k * 2];
            if (bOffset == 0) continue;

            size_t papxOff = bOffset * 2;
            if (papxOff >= 511) continue;
            uint8_t cb = fkp[papxOff];

            size_t grpprlOff, grpprlSz;
            if (cb == 0) {
                uint8_t cbP = fkp[papxOff + 1];
                grpprlOff = papxOff + 4;
                grpprlSz = cbP * 2 - 2;
            } else {
                grpprlOff = papxOff + 3;
                grpprlSz = cb * 2 - 3;
            }
            if (grpprlSz == 0 || grpprlOff + grpprlSz > 511) continue;

            size_t pos = 0;
            bool hasInTable = false, hasTtp = false;
            while (pos < grpprlSz) {
                SprmInfo sprm;
                if (!parseSprm(fkp + grpprlOff, grpprlSz, pos, sprm)) break;
                if (sprm.ispmd == 0x4B && sprm.sgc == 1 && sprm.operand.size() >= 2) {
                    uint32_t off = sprm.operand[0] | (sprm.operand[1] << 8) |
                                   (sprm.operand.size() >= 4 ? (sprm.operand[2] << 16) | (sprm.operand[3] << 24) : 0);
                    // Only add unique offsets
                    bool dup = false;
                    for (uint32_t o : prcOffsets) { if (o == off) { dup = true; break; } }
                    if (!dup) {
                        prcOffsets.push_back(off);
                        OH_LOG_INFO(LOG_APP, "DOC: Found sprmPTableProps: PrcOffset=%{public}d (bOffset=%{public}d)",
                                    (int)off, (int)bOffset);
                    }
                }
                if (sprm.ispmd == 0x16 && sprm.sgc == 1 && !sprm.operand.empty() && sprm.operand[0] == 1) {
                    hasInTable = true;
                }
                if (sprm.ispmd == 0x17 && sprm.sgc == 1 && !sprm.operand.empty() && sprm.operand[0] == 1) {
                    hasTtp = true;
                }
            }
            // Record row-start markers: paragraphs with sprmPFInTable=1 but no sprmPFTtp.
            // These mark the first paragraph of each row in tables where TTP marks
            // have bOffset=0 (no inline PAPX) — e.g. Table 2 in test_complex_tables.doc.
            if (hasInTable && !hasTtp) {
                uint32_t fcStart = fkp[k * 4] | (fkp[k * 4 + 1] << 8) |
                                   (fkp[k * 4 + 2] << 16) | (fkp[k * 4 + 3] << 24);
                uint32_t fcEnd = fkp[(k+1) * 4] | (fkp[(k+1) * 4 + 1] << 8) |
                                 (fkp[(k+1) * 4 + 2] << 16) | (fkp[(k+1) * 4 + 3] << 24);
                rowStarts.push_back({fcStart, fcEnd});
            }
        }
    }

    OH_LOG_INFO(LOG_APP, "DOC: Found %{public}d unique Prc offsets", (int)prcOffsets.size());

    // Step 1b: Pre-cache sprmTDefTable from each Prc in the Data stream.
    // Many TTP paragraphs have sprmPTableProps pointing to a Prc that contains
    // sprmTDefTable, but their own PAPX grpprl does NOT contain sprmTDefTable.
    // We need to cache the Prc's TDefTable so we can assign it to those paragraphs.
    std::map<uint32_t, TtpRowInfo> prcTDefCache;  // prcOffset → rowInfo
    for (uint32_t prcOffset : prcOffsets) {
        if (prcOffset + 4 >= dataStream.size()) continue;
        uint16_t cbGrpprl = dataStream[prcOffset] | (dataStream[prcOffset + 1] << 8);
        if (cbGrpprl == 0 || prcOffset + 2 + cbGrpprl > dataStream.size()) continue;
        const uint8_t* grpprl = dataStream.data() + prcOffset + 2;
        size_t grpprlLen = cbGrpprl;
        size_t pos = 0;
        while (pos < grpprlLen) {
            SprmInfo sprm;
            if (!parseSprm(grpprl, grpprlLen, pos, sprm)) break;
            if (sprm.sgc == 5 && sprm.ispmd == 0x08 && sprm.operand.size() >= 3) {
                TtpRowInfo ri = parseTDefTableRowInfo(sprm.operand);
                if (ri.nCols > 0) {
                    prcTDefCache[prcOffset] = ri;
                    OH_LOG_INFO(LOG_APP, "DOC: Cached Prc[0x%{public}X] TDefTable: nCols=%{public}d",
                                (int)prcOffset, (int)ri.nCols);
                }
                break;  // Only one TDefTable per Prc
            }
        }
    }

    // Step 2: Try each Prc offset for sprmTDefTable, AND also scan PAPX grpprls
    // Prc structure in Data stream: cbGrpprl (2 bytes) + grpprl (cbGrpprl bytes)
    // NOTE: Empirically, the Prc in the Data stream does NOT have an istd prefix.
    // The grpprl starts directly after cbGrpprl.

    // First, scan PAPX grpprls for sprmTDefTable (ispmd=0x08, fSpec=1, sgc=5, spra=6)
    // sprmTDefTable encodes as 0xD608: ispmd=0x08, fSpec=1, sgc=5, spra=6.
    // Note: ispmd=0x08 (NOT 0x44) — see MS-DOC spec Table 32 (sprmTDefTable = 0xD608).
    // We walk every paragraph in every FKP page to capture per-row TC80 cell flags.
    for (const auto& entry : papxEntries) {
        uint32_t fkpOffset = entry.pn * 512;
        if (fkpOffset + 512 > wordDocData.size()) continue;
        const uint8_t* fkp = wordDocData.data() + fkpOffset;
        uint8_t cpara = fkp[511];
        if (cpara == 0 || cpara > 0x1D) continue;

        size_t rgbxBase = (cpara + 1) * 4;
        for (int k = 0; k < (int)cpara; k++) {
            // Compute FC range for this paragraph from FKP rgfc array.
            // NOTE: FKP rgfc stores FC (WordDocument byte offsets), NOT CP.
            // We use fcEnd (rgfc[k+1]) as the key for ttpRowInfoMap because
            // that's the paragraph-end FC, which uniquely identifies the TTP.
            uint32_t fcEnd = fkp[(k+1) * 4] | (fkp[(k+1) * 4 + 1] << 8) |
                             (fkp[(k+1) * 4 + 2] << 16) | (fkp[(k+1) * 4 + 3] << 24);

            uint8_t bOffset = fkp[rgbxBase + k * 2];
            if (bOffset == 0) continue;

            size_t papxOff = bOffset * 2;
            if (papxOff >= 511) continue;
            uint8_t cb = fkp[papxOff];

            size_t grpprlOff, grpprlSz;
            if (cb == 0) {
                uint8_t cbP = fkp[papxOff + 1];
                grpprlOff = papxOff + 4;
                grpprlSz = cbP * 2 - 2;
            } else {
                grpprlOff = papxOff + 3;
                grpprlSz = cb * 2 - 3;
            }
            if (grpprlSz == 0 || grpprlOff + grpprlSz > 511) continue;

            size_t pos = 0;
            bool foundTDef = false;
            int papxSprmCount = 0;
            while (pos < grpprlSz) {
                SprmInfo sprm;
                if (!parseSprm(fkp + grpprlOff, grpprlSz, pos, sprm)) break;
                papxSprmCount++;
                // Log all table-related SPRMs (sgc=5) for debugging
                if (sprm.sgc == 5) {
                    OH_LOG_INFO(LOG_APP, "DOC: PAPX[%{public}d,%{public}d] Sprm[%{public}d] sgc=5: ispmd=0x%{public}X, fSpec=%{public}d, spra=%{public}d, opLen=%{public}d (FC_end=%{public}d)",
                                (int)entry.pn, k, papxSprmCount, (int)sprm.ispmd, (int)sprm.fSpec, (int)sprm.spra, (int)sprm.operand.size(), (int)fcEnd);
                }
                // Also log paragraph-level SPRMs (sgc=1) for sprmPFInTable/sprmPFTtp detection
                if (sprm.sgc == 1) {
                    uint8_t opValue = sprm.operand.empty() ? 0 : sprm.operand[0];
                    OH_LOG_INFO(LOG_APP, "DOC: PAPX[%{public}d,%{public}d] Sprm[%{public}d] sgc=1: ispmd=0x%{public}X, fSpec=%{public}d, spra=%{public}d, opLen=%{public}d, opVal=%{public}d (FC_end=%{public}d)",
                                (int)entry.pn, k, papxSprmCount, (int)sprm.ispmd, (int)sprm.fSpec, (int)sprm.spra, (int)sprm.operand.size(), (int)opValue, (int)fcEnd);
                }
                if (sprm.sgc == 5 && sprm.ispmd == 0x08 && sprm.operand.size() >= 3) {
                    OH_LOG_INFO(LOG_APP, "DOC: sprmTDefTable found in PAPX! opLen=%{public}d, operand[0]=0x%{public}02X, operand[1]=%{public}d, operand[2]=%{public}d",
                                (int)sprm.operand.size(), (int)sprm.operand[0], (int)sprm.operand[1], (int)sprm.operand[2]);
                    if (globalColumnCount == 0) {
                        globalColumnCount = sprm.operand[2];  // [0]=size, [2]=NumberOfColumns
                    }
                    // Extract row geometry from TC80 (LibreOffice WW8TabBandDesc::ReadDef)
                    TtpRowInfo rowInfo = parseTDefTableRowInfo(sprm.operand);
                    if (rowInfo.nCols > 0) {
                        ttpRowInfoMap[fcEnd] = rowInfo;
                        OH_LOG_INFO(LOG_APP, "DOC: sprmTDefTable TC80 for FC_end=%{public}d: nCols=%{public}d",
                                    (int)fcEnd, (int)rowInfo.nCols);
                    }
                    foundTDef = true;
                    // Continue scanning — sprmTMerge may follow sprmTDefTable
                }
                // sprmTMerge (ispmd=0x24, fSpec=0, sgc=5, spra=2) — operand is ItcFirstLim (2 bytes)
                // Each occurrence marks cells [itcFirst, itcLim) as horizontally merged
                if (sprm.sgc == 5 && sprm.ispmd == 0x24 && sprm.operand.size() >= 2) {
                    MergeRange mr{sprm.operand[0], sprm.operand[1]};
                    ttpMergeRangesMap[fcEnd].push_back(mr);
                    OH_LOG_INFO(LOG_APP, "DOC: sprmTMerge for FC_end=%{public}d: itcFirst=%{public}d, itcLim=%{public}d",
                                (int)fcEnd, (int)mr.itcFirst, (int)mr.itcLim);
                }
            }
            // If this paragraph's PAPX did NOT contain sprmTDefTable directly,
            // check if it has sprmPTableProps pointing to a Prc that contains one.
            if (!foundTDef) {
                // Re-scan this paragraph's grpprl for sprmPTableProps
                size_t pos2 = 0;
                uint32_t prcOff = 0xFFFFFFFF;
                while (pos2 < grpprlSz) {
                    SprmInfo sprm;
                    if (!parseSprm(fkp + grpprlOff, grpprlSz, pos2, sprm)) break;
                    if (sprm.ispmd == 0x4B && sprm.sgc == 1 && sprm.operand.size() >= 2) {
                        prcOff = sprm.operand[0] | (sprm.operand[1] << 8) |
                                 (sprm.operand.size() >= 4 ? (sprm.operand[2] << 16) | (sprm.operand[3] << 24) : 0);
                        break;
                    }
                }
                if (prcOff != 0xFFFFFFFF) {
                    auto cacheIt = prcTDefCache.find(prcOff);
                    if (cacheIt != prcTDefCache.end()) {
                        const TtpRowInfo& ri = cacheIt->second;
                        ttpRowInfoMap[fcEnd] = ri;
                        if (globalColumnCount == 0) globalColumnCount = ri.nCols;
                        OH_LOG_INFO(LOG_APP, "DOC: Prc-sourced TDefTable for FC_end=%{public}d: nCols=%{public}d (prcOff=0x%{public}X)",
                                    (int)fcEnd, (int)ri.nCols, (int)prcOff);
                    }
                }
            }
        }
    }

    // If not found in PAPX, try Prc in Data stream
    if (globalColumnCount == 0) {
        for (uint32_t prcOffset : prcOffsets) {
            if (prcOffset + 4 >= dataStream.size()) continue;

            uint16_t cbGrpprl = dataStream[prcOffset] | (dataStream[prcOffset + 1] << 8);
            OH_LOG_INFO(LOG_APP, "DOC: Trying Prc at offset %{public}d: cbGrpprl=%{public}d", (int)prcOffset, (int)cbGrpprl);
            if (cbGrpprl == 0 || prcOffset + 2 + cbGrpprl > dataStream.size()) continue;

            const uint8_t* grpprl = dataStream.data() + prcOffset + 2;
            size_t grpprlLen = cbGrpprl;

            // Dump first 30 bytes
            if (grpprlLen >= 10) {
                OH_LOG_INFO(LOG_APP, "DOC: Prc grpprl bytes=%{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X %{public}02X",
                            (int)grpprl[0], (int)grpprl[1], (int)grpprl[2], (int)grpprl[3],
                            (int)grpprl[4], (int)grpprl[5], (int)grpprl[6], (int)grpprl[7],
                            (int)grpprl[8], (int)grpprl[9], (int)grpprl[10], (int)grpprl[11],
                            (int)grpprl[12], (int)grpprl[13], (int)grpprl[14], (int)grpprl[15],
                            (int)grpprl[16], (int)grpprl[17], (int)grpprl[18], (int)grpprl[19],
                            (int)grpprl[20], (int)grpprl[21], (int)grpprl[22], (int)grpprl[23],
                            (int)grpprl[24], (int)grpprl[25], (int)grpprl[26], (int)grpprl[27],
                            (int)grpprl[28], (int)grpprl[29]);
            }

            // Search for sprmTDefTable header bytes (0x44 0xD4) in raw grpprl
            for (size_t s = 0; s + 1 < grpprlLen; s++) {
                if (grpprl[s] == 0x44 && grpprl[s+1] == 0xD4) {
                    OH_LOG_INFO(LOG_APP, "DOC: Found 0x44 0xD4 bytes at Prc grpprl pos %{public}d", (int)s);
                }
            }

            size_t pos = 0;
            int sprmCount = 0;
            while (pos < grpprlLen) {
                SprmInfo sprm;
                if (!parseSprm(grpprl, grpprlLen, pos, sprm)) {
                    OH_LOG_WARN(LOG_APP, "DOC: Prc parseSprm failed at pos=%{public}d/%{public}d", (int)pos, (int)grpprlLen);
                    break;
                }
                sprmCount++;

                // Log ALL Sprms for debugging
                OH_LOG_INFO(LOG_APP, "DOC: Prc Sprm[%{public}d] pos=%{public}d: ispmd=0x%{public}X, fSpec=%{public}d, sgc=%{public}d, spra=%{public}d, opLen=%{public}d",
                            sprmCount, (int)(pos - sprm.operand.size() - 2), (int)sprm.ispmd, (int)sprm.fSpec, (int)sprm.sgc, (int)sprm.spra, (int)sprm.operand.size());

                // sprmTDefTable (ispmd=0x08, sgc=5)
                if (sprm.sgc == 5 && sprm.ispmd == 0x08 && sprm.operand.size() >= 3) {
                    globalColumnCount = sprm.operand[2];  // [0]=size, [2]=NumberOfColumns
                    OH_LOG_INFO(LOG_APP, "DOC: Found sprmTDefTable in Prc: NumberOfColumns=%{public}d", globalColumnCount);
                    break;
                }
            }
            OH_LOG_INFO(LOG_APP, "DOC: Prc at offset %{public}d: parsed %{public}d Sprms", (int)prcOffset, sprmCount);
            if (globalColumnCount > 0) break;
        }
    }

    OH_LOG_INFO(LOG_APP, "DOC: Pre-scan result: globalColumnCount=%{public}d, ttpRowInfoMap.size=%{public}d",
                globalColumnCount, (int)ttpRowInfoMap.size());

    // Dump all TTP row info for debugging
    {
        std::string ttpDump;
        for (const auto& [fcEnd, ri] : ttpRowInfoMap) {
            char buf[80];
            snprintf(buf, sizeof(buf), "[FC=%u nCols=%d cells=", (unsigned)fcEnd, (int)ri.nCols);
            ttpDump += buf;
            for (size_t i = 0; i < ri.cells.size() && i < 10; i++) {
                char cellBuf[16];
                snprintf(cellBuf, sizeof(cellBuf), "%d%d",
                         (int)ri.cells[i].bFirstMerged, (int)ri.cells[i].bMerged);
                ttpDump += cellBuf;
                if (i + 1 < ri.cells.size()) ttpDump += ",";
            }
            ttpDump += "] ";
            if (ttpDump.size() > 900) { ttpDump += "..."; break; }
        }
        OH_LOG_INFO(LOG_APP, "DOC: TTP map dump: %{public}s", ttpDump.c_str());
    }

    // Run LibreOffice-style sequential table scan to detect table regions.
    // This produces a list of TableRegion objects with FC ranges for each row,
    // correctly handling bOffset=0 paragraphs that fall within row FC ranges.
    auto tableRegions = scanTablesSequential(
        papxEntries, wordDocData.data(), wordDocData.size(),
        ttpRowInfoMap, rowStarts,
        dataStream.empty() ? nullptr : dataStream.data(),
        dataStream.size());

    // Helper: check if an FC position falls within any TableRegion
    auto findTableRegion = [&](uint32_t fc) -> int {
        for (size_t ti = 0; ti < tableRegions.size(); ti++) {
            if (fc >= tableRegions[ti].startFc && fc <= tableRegions[ti].endFc + 100) {
                return (int)ti;
            }
        }
        return -1;
    };

    // Helper: check if an FC position falls within any row of a TableRegion
    auto findRowInRegion = [&](int regionIdx, uint32_t fc) -> int {
        if (regionIdx < 0 || regionIdx >= (int)tableRegions.size()) return -1;
        const auto& region = tableRegions[regionIdx];
        for (size_t ri = 0; ri < region.rows.size(); ri++) {
            if (fc >= region.rows[ri].firstCellFc && fc <= region.rows[ri].lastCellFc + 10) {
                return (int)ri;
            }
        }
        return -1;
    };

    // Second pass: group segments into paragraphs and tables
    // Uses scanTablesSequential results for authoritative table boundary detection.
    // Segments whose FC falls within a TableRegion are table cells.
    // All other segments are regular paragraphs.
    size_t i = 0;
    while (i < segments.size()) {
        // Check if this segment is in a table region
        int regionIdx = findTableRegion(segments[i].fcPosition);

        if (regionIdx >= 0 && (segments[i].delimiter == '\x07' ||
                               (segments[i].delimiter == '\r' &&
                                findRowInRegion(regionIdx, segments[i].fcPosition) >= 0))) {
            // ----------------------------------------------------------------
            // Collect all segments within this TableRegion.
            // The region boundaries are authoritative — we don't need to
            // check isInTable() per segment.
            // ----------------------------------------------------------------
            struct CellInfo {
                std::string text;
                uint32_t cp;
                uint32_t fc;
                bool isTtp;  // true if this segment is a TTP row terminator
            };
            std::vector<CellInfo> cells;
            std::string pendingIntraCellText;
            size_t j = i;
            const auto& region = tableRegions[regionIdx];

            while (j < segments.size()) {
                // Stop if segment is outside the current table region
                if (segments[j].fcPosition > region.endFc + 100) break;

                bool inThisRegion = (segments[j].fcPosition >= region.startFc &&
                                     segments[j].fcPosition <= region.endFc + 100);

                if (segments[j].delimiter == '\x07') {
                    // Cell mark — always a table cell
                    std::string cleanCell;
                    for (char c : segments[j].text) {
                        if (c != '\x01') cleanCell += c;
                    }
                    cleanCell = trimTrailing(cleanCell);

                    // Merge any pending intra-cell text
                    if (!pendingIntraCellText.empty()) {
                        cleanCell = pendingIntraCellText + (cleanCell.empty() ? "" : "\n") + cleanCell;
                        pendingIntraCellText.clear();
                    }

                    // Check if this \x07 is a TTP (last cell in a row)
                    uint32_t fcPlus1 = segments[j].fcPosition + 1;
                    uint32_t fcPlus2 = segments[j].fcPosition + 2;
                    bool isTTP = (ttpRowInfoMap.find(fcPlus1) != ttpRowInfoMap.end() ||
                                  ttpRowInfoMap.find(fcPlus2) != ttpRowInfoMap.end() ||
                                  ttpMergeRangesMap.find(fcPlus1) != ttpMergeRangesMap.end() ||
                                  ttpMergeRangesMap.find(fcPlus2) != ttpMergeRangesMap.end());
                    if (!isTTP && !papxEntries.empty()) {
                        isTTP = isTtpMark(papxEntries, wordDocData.data(), wordDocData.size(),
                                         segments[j].fcPosition, segments[j].cpPosition,
                                         dataStream.empty() ? nullptr : dataStream.data(),
                                         dataStream.size());
                    }

                    cells.push_back({cleanCell, segments[j].cpPosition, segments[j].fcPosition, isTTP});
                    j++;
                } else if (segments[j].delimiter == '\r' && inThisRegion) {
                    // \r inside table region — check if it's a TTP, row-start, or content
                    uint32_t fcPlus1 = segments[j].fcPosition + 1;
                    uint32_t fcPlus2 = segments[j].fcPosition + 2;

                    // Check TTP via map
                    bool isTTP = (ttpRowInfoMap.find(fcPlus1) != ttpRowInfoMap.end() ||
                                  ttpRowInfoMap.find(fcPlus2) != ttpRowInfoMap.end() ||
                                  ttpMergeRangesMap.find(fcPlus1) != ttpMergeRangesMap.end() ||
                                  ttpMergeRangesMap.find(fcPlus2) != ttpMergeRangesMap.end());
                    // Check TTP via isTtpMark
                    if (!isTTP && !papxEntries.empty()) {
                        isTTP = isTtpMark(papxEntries, wordDocData.data(), wordDocData.size(),
                                         segments[j].fcPosition, segments[j].cpPosition,
                                         dataStream.empty() ? nullptr : dataStream.data(),
                                         dataStream.size());
                    }

                    if (isTTP) {
                        // TTP row-end marker
                        if (!pendingIntraCellText.empty()) {
                            if (!cells.empty()) {
                                if (cells.back().text.empty()) {
                                    cells.back().text = pendingIntraCellText;
                                } else {
                                    cells.back().text += "\n" + pendingIntraCellText;
                                }
                            }
                            pendingIntraCellText.clear();
                        }
                        cells.push_back({"", segments[j].cpPosition, segments[j].fcPosition, true});
                        OH_LOG_INFO(LOG_APP, "DOC: \\r at CP=%{public}d → TTP (in region)", (int)segments[j].cpPosition);
                    } else {
                        // Intra-cell content paragraph (row-start or bOffset=0 content)
                        if (!segments[j].text.empty()) {
                            std::string cleanText = trimTrailing(segments[j].text);
                            if (!cleanText.empty()) {
                                if (!pendingIntraCellText.empty()) {
                                    pendingIntraCellText += "\n";
                                }
                                pendingIntraCellText += cleanText;
                            }
                        }
                        OH_LOG_INFO(LOG_APP, "DOC: \\r at CP=%{public}d → content (in region)", (int)segments[j].cpPosition);
                    }
                    j++;
                } else {
                    // Segment is outside this table region or has other delimiter
                    break;
                }
            }

            // Flush any remaining pending text
            if (!pendingIntraCellText.empty() && !cells.empty()) {
                if (cells.back().text.empty()) {
                    cells.back().text = pendingIntraCellText;
                } else {
                    cells.back().text += "\n" + pendingIntraCellText;
                }
                pendingIntraCellText.clear();
            }

            int totalCells = (int)cells.size();
            OH_LOG_INFO(LOG_APP, "DOC: TableRegion[%{public}d]: collected %{public}d cells",
                        regionIdx, totalCells);

            // Build rows from cells using TTP markers
            // Find all TTP positions
            std::vector<int> ttpPositions;
            for (int k = 0; k < totalCells; k++) {
                if (cells[k].isTtp) {
                    ttpPositions.push_back(k);
                }
            }

            // If no TTPs found, try fallback: use detectedCols from ttpRowInfoMap
            if (ttpPositions.empty() && globalColumnCount > 0) {
                int cellsPerRow = globalColumnCount + 1;  // nCols data cells + 1 TTP
                if (totalCells % cellsPerRow == 0) {
                    int numRows = totalCells / cellsPerRow;
                    for (int r = 0; r < numRows; r++) {
                        ttpPositions.push_back((r + 1) * cellsPerRow - 1);
                    }
                    OH_LOG_INFO(LOG_APP, "DOC: Fallback TTP injection: %{public}d rows × %{public}d cols",
                                numRows, globalColumnCount);
                }
            }

            // If still no TTPs, try divisibility heuristic
            if (ttpPositions.empty()) {
                for (int tryCols = 2; tryCols <= 10; tryCols++) {
                    int cellsPerRow = tryCols + 1;
                    if (totalCells % cellsPerRow == 0) {
                        int numRows = totalCells / cellsPerRow;
                        for (int r = 0; r < numRows; r++) {
                            ttpPositions.push_back((r + 1) * cellsPerRow - 1);
                        }
                        OH_LOG_INFO(LOG_APP, "DOC: Divisibility fallback: %{public}d rows × %{public}d cols",
                                    numRows, tryCols);
                        break;
                    }
                }
            }

            // Split into per-table groups by rgdxaCenter similarity
            // (same logic as before: tables with different column structures are separate)
            auto lookupRowInfo = [&](int cellIdx) -> const TtpRowInfo* {
                auto it = ttpRowInfoMap.find(cells[cellIdx].fc + 1);
                if (it == ttpRowInfoMap.end()) {
                    it = ttpRowInfoMap.find(cells[cellIdx].fc + 2);
                }
                return (it != ttpRowInfoMap.end()) ? &it->second : nullptr;
            };

            auto rgdxaSet = [](const TtpRowInfo* ri) -> std::set<uint16_t> {
                std::set<uint16_t> s;
                if (ri) for (uint16_t v : ri->rgdxaCenter) s.insert(v);
                return s;
            };

            // Group TTPs into separate tables by column structure
            std::vector<std::vector<int>> ttpGroups;
            std::vector<int> currentGroup;
            std::set<uint16_t> prevSet;
            for (int ttpIdx : ttpPositions) {
                const TtpRowInfo* ri = lookupRowInfo(ttpIdx);
                std::set<uint16_t> curSet = rgdxaSet(ri);
                if (!currentGroup.empty() && !curSet.empty() && !prevSet.empty()) {
                    int common = 0;
                    for (uint16_t v : curSet) {
                        if (v != 65428 && prevSet.count(v)) common++;
                    }
                    if (common < 2) {
                        ttpGroups.push_back(currentGroup);
                        currentGroup.clear();
                    }
                }
                currentGroup.push_back(ttpIdx);
                prevSet = curSet;
            }
            if (!currentGroup.empty()) ttpGroups.push_back(currentGroup);

            OH_LOG_INFO(LOG_APP, "DOC: Grouped %{public}d TTPs into %{public}d tables",
                        (int)ttpPositions.size(), (int)ttpGroups.size());

            // Build rows from each group
            auto emitTable = [&](const std::vector<std::vector<DocTableCell>>& rows) -> bool {
                bool isTable = (rows.size() >= 2) ||
                               (rows.size() == 1 && rows[0].size() >= 2);
                if (isTable && !rows.empty()) {
                    DocContentElement elem;
                    elem.type = DocElementType::TABLE;
                    for (const auto& row : rows) {
                        DocTableRow tr;
                        for (const auto& cell : row) {
                            tr.cells.push_back(cell);
                        }
                        elem.table.rows.push_back(tr);
                    }
                    elements.push_back(elem);
                    return true;
                } else {
                    for (const auto& row : rows) {
                        for (const auto& cell : row) {
                            if (!cell.text.empty()) {
                                DocContentElement elem;
                                elem.type = DocElementType::PARAGRAPH;
                                elem.text = cell.text;
                                elements.push_back(elem);
                            }
                        }
                    }
                    return false;
                }
            };

            for (size_t g = 0; g < ttpGroups.size(); g++) {
                const auto& group = ttpGroups[g];
                int firstCellIdx = (g == 0) ? 0 : ttpGroups[g-1].back() + 1;

                // Build reference grid from this group's rgdxaCenter union
                std::set<uint16_t> refGridSet;
                for (int ttpIdx : group) {
                    const TtpRowInfo* ri = lookupRowInfo(ttpIdx);
                    if (ri) for (uint16_t xas : ri->rgdxaCenter) refGridSet.insert(xas);
                }
                std::vector<uint16_t> refGrid(refGridSet.begin(), refGridSet.end());

                int prevTtp = firstCellIdx - 1;
                std::vector<std::vector<DocTableCell>> thisTableRows;
                for (int ttpIdx : group) {
                    const TtpRowInfo* rowInfo = lookupRowInfo(ttpIdx);
                    auto mrIt = ttpMergeRangesMap.find(cells[ttpIdx].fc + 1);
                    if (mrIt == ttpMergeRangesMap.end()) {
                        mrIt = ttpMergeRangesMap.find(cells[ttpIdx].fc + 2);
                    }
                    std::vector<MergeRange> mergeRanges = (mrIt != ttpMergeRangesMap.end())
                        ? mrIt->second : std::vector<MergeRange>{};

                    // Compute per-cell gridSpan from rgdxaCenter vs refGrid
                    std::vector<int> cellSpan;
                    if (rowInfo && rowInfo->nCols > 0 &&
                        rowInfo->rgdxaCenter.size() == (size_t)(rowInfo->nCols + 1) &&
                        refGrid.size() >= 2) {
                        for (uint8_t c = 0; c < rowInfo->nCols; c++) {
                            uint16_t left = rowInfo->rgdxaCenter[c];
                            uint16_t right = rowInfo->rgdxaCenter[c + 1];
                            int span = 0;
                            for (size_t gi = 0; gi + 1 < refGrid.size(); gi++) {
                                uint16_t gLeft = refGrid[gi];
                                uint16_t gRight = refGrid[gi + 1];
                                if (left <= gLeft && right >= gRight) {
                                    span++;
                                }
                            }
                            cellSpan.push_back(span > 0 ? span : 1);
                        }
                    }

                    std::vector<DocTableCell> row;
                    int cellIdx = 0;
                    for (int k = prevTtp + 1; k < ttpIdx; k++, cellIdx++) {
                        // LibreOffice bMerged (bit 1): cell merged with preceding cell
                        // bFirstMerged (bit 0): first cell of merge range (NOT continuation)
                        bool isContinuation = false;
                        if (rowInfo && cellIdx < (int)rowInfo->cells.size()) {
                            // LibreOffice WW8_TCell.bMerged == 1 means continuation
                            if (rowInfo->cells[cellIdx].bMerged == 1) {
                                isContinuation = true;
                            }
                        }
                        if (!isContinuation && !mergeRanges.empty()) {
                            for (const auto& mr : mergeRanges) {
                                if (cellIdx >= mr.itcFirst && cellIdx < mr.itcLim) {
                                    if (cellIdx > mr.itcFirst) isContinuation = true;
                                    break;
                                }
                            }
                        }

                        if (isContinuation && !row.empty()) {
                            row.back().colSpan += 1;
                            if (!cells[k].text.empty()) {
                                row.back().text += (row.back().text.empty() ? "" : "\n") + cells[k].text;
                            }
                        } else {
                            DocTableCell tc;
                            tc.text = cells[k].text;
                            tc.colSpan = (cellIdx < (int)cellSpan.size()) ? cellSpan[cellIdx] : 1;
                            row.push_back(tc);
                        }
                    }
                    if (!row.empty()) {
                        thisTableRows.push_back(row);
                    }
                    prevTtp = ttpIdx;
                }
                if (!thisTableRows.empty()) {
                    emitTable(thisTableRows);
                }
            }

            // If no TTP groups at all, try simple fallback
            if (ttpGroups.empty() && totalCells > 0) {
                // Single row fallback
                std::vector<DocTableCell> row;
                for (int k = 0; k < totalCells; k++) {
                    if (!cells[k].isTtp) {
                        DocTableCell tc;
                        tc.text = cells[k].text;
                        tc.colSpan = 1;
                        row.push_back(tc);
                    }
                }
                std::vector<std::vector<DocTableCell>> fallbackRows;
                if (!row.empty()) fallbackRows.push_back(row);
                emitTable(fallbackRows);
            }

            i = j;
        } else {
            // Regular paragraph
            std::string text = segments[i].text;
            // Check for image placeholders
            bool hasImage = text.find('\x01') != std::string::npos;

            if (hasImage) {
                // Split around image markers
                size_t pos = 0;
                while (pos < text.size()) {
                    size_t imgPos = text.find('\x01', pos);
                    if (imgPos == std::string::npos) {
                        std::string remaining = trimTrailing(text.substr(pos));
                        if (!remaining.empty()) {
                            DocContentElement elem;
                            elem.type = DocElementType::PARAGRAPH;
                            elem.text = remaining;
                            elements.push_back(elem);
                        }
                        break;
                    }
                    if (imgPos > pos) {
                        std::string before = trimTrailing(text.substr(pos, imgPos - pos));
                        if (!before.empty()) {
                            DocContentElement elem;
                            elem.type = DocElementType::PARAGRAPH;
                            elem.text = before;
                            elements.push_back(elem);
                        }
                    }
                    // Add image placeholder
                    DocContentElement imgElem;
                    imgElem.type = DocElementType::IMAGE_PLACEHOLDER;
                    imgElem.imageIndex = 0;  // Will be resolved later
                    elements.push_back(imgElem);
                    pos = imgPos + 1;
                }
            } else {
                if (!text.empty()) {
                    DocContentElement elem;
                    elem.type = DocElementType::PARAGRAPH;
                    elem.text = text;
                    elements.push_back(elem);
                }
            }
            i++;
        }
    }

    return elements;
}

/**
 * Scan the Data stream for embedded images (PNG, JPEG, EMF, WMF, BMP).
 * Returns pairs of (image data, file extension).
 */
struct ExtractedImage {
    std::vector<uint8_t> data;
    std::string extension;  // "png", "jpeg", "emf", "wmf", "bmp"
    std::string mimeType;
};

static std::vector<ExtractedImage> extractImagesFromDataStream(const std::vector<uint8_t>& dataStream) {
    std::vector<ExtractedImage> images;
    if (dataStream.size() < 10) return images;

    const uint8_t* data = dataStream.data();
    size_t size = dataStream.size();

    // Scan for image signatures
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    // JPEG: FF D8 FF
    // EMF: starts with EMR_HEADER (record type 1) - harder to detect
    // WMF: D7 CD C6 9A (placeable) or 01 00 (standard)
    // BMP: 42 4D ("BM")

    for (size_t pos = 0; pos < size; ) {
        // PNG signature
        if (pos + 8 <= size && data[pos] == 0x89 && data[pos+1] == 'P' &&
            data[pos+2] == 'N' && data[pos+3] == 'G') {
            // Find end of PNG (IEND chunk)
            size_t pngEnd = pos + 8;
            while (pngEnd + 12 <= size) {
                uint32_t chunkLen = (data[pngEnd] << 24) | (data[pngEnd+1] << 16) |
                                    (data[pngEnd+2] << 8) | data[pngEnd+3];
                std::string chunkType(data + pngEnd + 4, data + pngEnd + 8);
                pngEnd += 12 + chunkLen;  // 4 len + 4 type + data + 4 crc
                if (chunkType == "IEND") break;
                if (chunkLen > size) break;  // Sanity check
            }
            if (pngEnd > pos && pngEnd <= size) {
                ExtractedImage img;
                img.extension = "png";
                img.mimeType = "image/png";
                img.data.assign(data + pos, data + pngEnd);
                images.push_back(img);
                OH_LOG_INFO(LOG_APP, "DOC: Found PNG image at offset %{public}d, size=%{public}d",
                           (int)pos, (int)img.data.size());
                pos = pngEnd;
                continue;
            }
        }

        // JPEG signature
        if (pos + 3 <= size && data[pos] == 0xFF && data[pos+1] == 0xD8 && data[pos+2] == 0xFF) {
            // Find JPEG end marker (FF D9)
            size_t jpegEnd = pos + 3;
            while (jpegEnd + 1 < size) {
                if (data[jpegEnd] == 0xFF && data[jpegEnd+1] == 0xD9) {
                    jpegEnd += 2;
                    break;
                }
                jpegEnd++;
            }
            if (jpegEnd > pos && jpegEnd <= size) {
                ExtractedImage img;
                img.extension = "jpeg";
                img.mimeType = "image/jpeg";
                img.data.assign(data + pos, data + jpegEnd);
                images.push_back(img);
                OH_LOG_INFO(LOG_APP, "DOC: Found JPEG image at offset %{public}d, size=%{public}d",
                           (int)pos, (int)img.data.size());
                pos = jpegEnd;
                continue;
            }
        }

        // BMP signature
        if (pos + 4 <= size && data[pos] == 'B' && data[pos+1] == 'M') {
            uint32_t bmpSize = data[pos+2] | (data[pos+3] << 8) |
                              (data[pos+4] << 16) | (data[pos+5] << 24);
            if (bmpSize > 0 && bmpSize <= size - pos && bmpSize < 10000000) {
                ExtractedImage img;
                img.extension = "bmp";
                img.mimeType = "image/bmp";
                img.data.assign(data + pos, data + pos + bmpSize);
                images.push_back(img);
                OH_LOG_INFO(LOG_APP, "DOC: Found BMP image at offset %{public}d, size=%{public}d",
                           (int)pos, (int)bmpSize);
                pos += bmpSize;
                continue;
            }
        }

        pos++;
    }

    OH_LOG_INFO(LOG_APP, "DOC: Total images extracted from Data stream: %{public}d", (int)images.size());
    return images;
}

bool OfficeConverter::convertDOC(const std::string& inputPath, const std::string& outputPath,
                                  ConversionResult& result) {
    OH_LOG_INFO(LOG_APP, "OfficeConverter: convertDOC start, input=%{public}s", inputPath.c_str());

    // Remove file:// prefix and ensure absolute path
    std::string filePath = inputPath;
    if (filePath.find("file://") == 0) {
        filePath = filePath.substr(7);
    }
    if (filePath.length() > 0 && filePath[0] != '/') {
        filePath = "/" + filePath;
    }

    // Read file
    FILE* file = fopen(filePath.c_str(), "rb");
    if (!file) {
        result.errorMsg = "Cannot open file: " + filePath;
        return false;
    }

    fseek(file, 0, SEEK_END);
    size_t fileSize = ftell(file);
    fseek(file, 0, SEEK_SET);

    std::vector<uint8_t> fileData(fileSize);
    fread(fileData.data(), 1, fileSize, file);
    fclose(file);

    OH_LOG_INFO(LOG_APP, "DOC: File size: %{public}d bytes", (int)fileSize);

    // Step 1: Parse OLE2 structure to find streams
    std::vector<OLE2Entry> entries;
    if (!parseOLE2Header(fileData.data(), fileSize, entries)) {
        result.errorMsg = "Failed to parse OLE2 header";
        return false;
    }

    // Find required streams
    const OLE2Entry* wordDocEntry = nullptr;
    const OLE2Entry* table0Entry = nullptr;
    const OLE2Entry* table1Entry = nullptr;

    for (const auto& entry : entries) {
        if (entry.name == "WordDocument") wordDocEntry = &entry;
        else if (entry.name == "0Table") table0Entry = &entry;
        else if (entry.name == "1Table") table1Entry = &entry;
    }

    if (!wordDocEntry) {
        result.errorMsg = "WordDocument stream not found";
        return false;
    }

    OH_LOG_INFO(LOG_APP, "DOC: Found WordDocument (size=%{public}d), 0Table=%{public}d, 1Table=%{public}d",
                (int)wordDocEntry->size,
                table0Entry ? (int)table0Entry->size : -1,
                table1Entry ? (int)table1Entry->size : -1);

    // Step 2: Read WordDocument stream
    std::vector<uint8_t> wordDocData;
    if (!readOLE2Stream(fileData.data(), fileSize, *wordDocEntry, wordDocData)) {
        result.errorMsg = "Failed to read WordDocument stream";
        return false;
    }

    OH_LOG_INFO(LOG_APP, "DOC: WordDocument stream read: %{public}d bytes", (int)wordDocData.size());

    // Step 3: Parse FIB to find piece table location
    FibParseResult fib = parseFIB(wordDocData);

    // Step 4: Read the appropriate table stream (0Table or 1Table)
    std::vector<uint8_t> tableData;
    const OLE2Entry* tableEntry = fib.useTable1 ? table1Entry : table0Entry;

    if (tableEntry) {
        if (!readOLE2Stream(fileData.data(), fileSize, *tableEntry, tableData)) {
            OH_LOG_WARN(LOG_APP, "DOC: Failed to read %{public}s stream",
                        fib.useTable1 ? "1Table" : "0Table");
        }
    }

    OH_LOG_INFO(LOG_APP, "DOC: Table stream (%{public}s) read: %{public}d bytes",
                fib.useTable1 ? "1Table" : "0Table", (int)tableData.size());

    // Read Data stream early for PAP parsing (PrcData contains table row properties)
    std::vector<uint8_t> dataStream;
    for (const auto& entry : entries) {
        if (entry.name == "Data") {
            readOLE2Stream(fileData.data(), fileSize, entry, dataStream);
            OH_LOG_INFO(LOG_APP, "DOC: Data stream read: %{public}d bytes (for PrcData)", (int)dataStream.size());
            break;
        }
    }

    // Step 5: Parse piece table and extract structured content
    std::vector<DocContentElement> contentElements;
    std::vector<TextPiece> pieces;

    if (fib.valid && fib.lcbClx > 0 && tableData.size() > 0) {
        OH_LOG_INFO(LOG_APP, "DOC: Parsing piece table (fcClx=%{public}d, lcbClx=%{public}d)",
                    (int)fib.fcClx, (int)fib.lcbClx);

        pieces = parsePieceTable(tableData.data(), tableData.size(),
                                 fib.fcClx, fib.lcbClx);

        OH_LOG_INFO(LOG_APP, "DOC: Parsed %{public}d text pieces", (int)pieces.size());

        if (!pieces.empty()) {
            contentElements = extractDocContent(wordDocData, tableData, dataStream, fib, pieces);
        }
    }

    // Fallback if piece table parsing failed
    if (contentElements.empty()) {
        OH_LOG_WARN(LOG_APP, "DOC: Piece table parsing failed, trying fallback");

        std::vector<uint8_t> altTableData;
        const OLE2Entry* altTableEntry = fib.useTable1 ? table0Entry : table1Entry;
        if (altTableEntry) {
            readOLE2Stream(fileData.data(), fileSize, *altTableEntry, altTableData);
        }

        if (!altTableData.empty() && fib.valid && fib.lcbClx > 0) {
            auto altPieces = parsePieceTable(altTableData.data(), altTableData.size(),
                                              fib.fcClx, fib.lcbClx);
            if (!altPieces.empty()) {
                contentElements = extractDocContent(wordDocData, altTableData, dataStream, fib, altPieces);
            }
        }

        // Last resort: scan for text
        if (contentElements.empty()) {
            OH_LOG_WARN(LOG_APP, "DOC: All parsing failed, scanning for text patterns");
            std::string allText;
            for (size_t offset = 0; offset + 1 < wordDocData.size(); offset += 2) {
                uint16_t ch = wordDocData[offset] | (wordDocData[offset + 1] << 8);
                if (ch >= 0x4E00 && ch <= 0x9FFF) {
                    char buf[4];
                    buf[0] = (char)(0xE0 | (ch >> 12));
                    buf[1] = (char)(0x80 | ((ch >> 6) & 0x3F));
                    buf[2] = (char)(0x80 | (ch & 0x3F));
                    allText.append(buf, 3);
                } else if (ch >= 0x20 && ch < 0x80) {
                    allText += (char)ch;
                } else if (ch == 0x000D) {
                    allText += '\r';
                }
            }
            size_t start = 0;
            while (start < allText.size()) {
                size_t end = allText.find('\r', start);
                if (end == std::string::npos) end = allText.size();
                std::string para = trimTrailing(allText.substr(start, end - start));
                if (!para.empty()) {
                    DocContentElement elem;
                    elem.type = DocElementType::PARAGRAPH;
                    elem.text = para;
                    contentElements.push_back(elem);
                }
                start = end + 1;
            }
        }
    }

    if (contentElements.empty()) {
        DocContentElement elem;
        elem.type = DocElementType::PARAGRAPH;
        elem.text = "(Empty document)";
        contentElements.push_back(elem);
    }

    // Count content types
    int paraCount = 0, tableCount = 0, imageCount = 0;
    for (const auto& elem : contentElements) {
        if (elem.type == DocElementType::PARAGRAPH) paraCount++;
        else if (elem.type == DocElementType::TABLE) tableCount++;
        else if (elem.type == DocElementType::IMAGE_PLACEHOLDER) imageCount++;
    }
    OH_LOG_INFO(LOG_APP, "DOC: Content: %{public}d paragraphs, %{public}d tables, %{public}d image placeholders",
                paraCount, tableCount, imageCount);

    // Step 6: Extract images from Data stream
    std::vector<ExtractedImage> images;
    for (const auto& entry : entries) {
        if (entry.name == "Data") {
            std::vector<uint8_t> dataStream;
            if (readOLE2Stream(fileData.data(), fileSize, entry, dataStream)) {
                OH_LOG_INFO(LOG_APP, "DOC: Data stream size: %{public}d bytes", (int)dataStream.size());
                images = extractImagesFromDataStream(dataStream);
            }
            break;
        }
    }

    // Also check ObjectPool storage for images
    if (images.empty()) {
        for (const auto& entry : entries) {
            if (entry.name.find("ObjectPool") != std::string::npos ||
                entry.name.find("ObjInfo") != std::string::npos) {
                OH_LOG_INFO(LOG_APP, "DOC: Found ObjectPool entry: %{public}s (size=%{public}d)",
                            entry.name.c_str(), (int)entry.size);
            }
        }
    }

    // Step 7: Generate DOCX structure
    std::vector<std::pair<std::string, std::vector<uint8_t>>> docxFiles;

    // Build content types
    std::string contentTypes =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        "<Default Extension=\"xml\" ContentType=\"application/xml\"/>";

    // Add image content types if we have images
    bool hasPng = false, hasJpeg = false, hasBmp = false;
    for (const auto& img : images) {
        if (img.extension == "png") hasPng = true;
        else if (img.extension == "jpeg") hasJpeg = true;
        else if (img.extension == "bmp") hasBmp = true;
    }
    if (hasPng) contentTypes += "<Default Extension=\"png\" ContentType=\"image/png\"/>";
    if (hasJpeg) contentTypes += "<Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>";
    if (hasBmp) contentTypes += "<Default Extension=\"bmp\" ContentType=\"image/bmp\"/>";

    contentTypes +=
        "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        "</Types>";
    docxFiles.push_back({"[Content_Types].xml", std::vector<uint8_t>(contentTypes.begin(), contentTypes.end())});

    // _rels/.rels
    std::string rels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
        "</Relationships>";
    docxFiles.push_back({"_rels/.rels", std::vector<uint8_t>(rels.begin(), rels.end())});

    // Add image files to docx
    int imageIdx = 0;
    for (const auto& img : images) {
        imageIdx++;
        std::string imgName = "word/media/image" + std::to_string(imageIdx) + "." + img.extension;
        docxFiles.push_back({imgName, img.data});
    }

    // Build document.xml.rels
    std::string docRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">";

    // Add image relationships
    for (int i = 0; i < (int)images.size(); i++) {
        std::string rId = "rIdImg" + std::to_string(i + 1);
        std::string target = "media/image" + std::to_string(i + 1) + "." + images[i].extension;
        docRels += "<Relationship Id=\"" + rId +
                   "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"" +
                   target + "\"/>";
    }
    docRels += "</Relationships>";

    // Build document.xml body
    std::string documentXml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<w:document xmlns:wpc=\"http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas\" "
        "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" "
        "xmlns:o=\"urn:schemas-microsoft-com:office:office\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\" "
        "xmlns:v=\"urn:schemas-microsoft-com:vml\" "
        "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" "
        "xmlns:w10=\"urn:schemas-microsoft-com:office:word\" "
        "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" "
        "xmlns:wne=\"http://schemas.microsoft.com/office/word/2006/wordml\">"
        "<w:body>";

    // Track next image to insert for image placeholders
    int nextImageIdx = 0;

    for (const auto& elem : contentElements) {
        if (elem.type == DocElementType::PARAGRAPH) {
            std::string escaped = xmlEscape(elem.text);
            documentXml += "<w:p><w:r><w:t xml:space=\"preserve\">" + escaped + "</w:t></w:r></w:p>";

        } else if (elem.type == DocElementType::TABLE) {
            const auto& tbl = elem.table;
            if (tbl.rows.empty()) continue;

            // Find max columns
            size_t maxCols = 0;
            for (const auto& row : tbl.rows) {
                if (row.cells.size() > maxCols) maxCols = row.cells.size();
            }
            if (maxCols == 0) continue;

            // Table properties
            documentXml += "<w:tbl>";
            documentXml += "<w:tblPr><w:tblStyle w:val=\"TableGrid\"/>"
                          "<w:tblW w:w=\"5000\" w:type=\"pct\"/>"
                          "<w:tblBorders>"
                          "<w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                          "<w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                          "<w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                          "<w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                          "<w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                          "<w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                          "</w:tblBorders></w:tblPr>";

            // Table grid (column widths)
            documentXml += "<w:tblGrid>";
            for (size_t c = 0; c < maxCols; c++) {
                documentXml += "<w:gridCol w:w=\"" + std::to_string(9000 / maxCols) + "\"/>";
            }
            documentXml += "</w:tblGrid>";

            // Table rows — with gridSpan support for merged cells
            for (const auto& row : tbl.rows) {
                documentXml += "<w:tr>";
                // Emit cells from the row data (each may span multiple grid columns)
                for (size_t c = 0; c < row.cells.size(); c++) {
                    std::string cellText = xmlEscape(row.cells[c].text);
                    int span = row.cells[c].colSpan;
                    if (span < 1) span = 1;

                    // Build tcPr with optional gridSpan
                    std::string tcPr = "<w:tcPr>";
                    if (span > 1) {
                        tcPr += "<w:gridSpan w:val=\"" + std::to_string(span) + "\"/>";
                    }
                    tcPr += "<w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr>";

                    // Handle multi-line cell text (\n → separate <w:p> elements)
                    std::string cellBody;
                    size_t lineStart = 0;
                    bool firstLine = true;
                    for (size_t ch = 0; ch <= cellText.size(); ch++) {
                        if (ch == cellText.size() || cellText[ch] == '\n') {
                            std::string line = cellText.substr(lineStart, ch - lineStart);
                            if (!firstLine) {
                                cellBody += "</w:p><w:p>";
                            }
                            cellBody += "<w:r><w:t xml:space=\"preserve\">" + line + "</w:t></w:r>";
                            firstLine = false;
                            lineStart = ch + 1;
                        }
                    }
                    if (cellBody.empty()) {
                        cellBody = "<w:r><w:t xml:space=\"preserve\"></w:t></w:r>";
                    }

                    documentXml += "<w:tc>" + tcPr +
                                  "<w:p>" + cellBody + "</w:p>"
                                  "</w:tc>";
                }
                documentXml += "</w:tr>";
            }
            documentXml += "</w:tbl>";

        } else if (elem.type == DocElementType::IMAGE_PLACEHOLDER) {
            // Insert image if available
            if (nextImageIdx < (int)images.size()) {
                std::string rId = "rIdImg" + std::to_string(nextImageIdx + 1);
                int imgW = 4000000;  // Default width in EMU (about 10cm)
                int imgH = 3000000;  // Default height in EMU
                std::string imgName = "image" + std::to_string(nextImageIdx + 1) + "." +
                                     images[nextImageIdx].extension;

                documentXml += "<w:p><w:r><w:drawing>"
                    "<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
                    "<wp:extent cx=\"" + std::to_string(imgW) + "\" cy=\"" + std::to_string(imgH) + "\"/>"
                    "<wp:docPr id=\"" + std::to_string(nextImageIdx + 1) + "\" name=\"" + imgName + "\"/>"
                    "<a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">"
                    "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
                    "<pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
                    "<pic:nvPicPr><pic:cNvPr id=\"" + std::to_string(nextImageIdx + 1) +
                    "\" name=\"" + imgName + "\"/>"
                    "<pic:cNvPicPr/></pic:nvPicPr>"
                    "<pic:blipFill><a:blip r:embed=\"" + rId + "\"/>"
                    "<a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
                    "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/>"
                    "<a:ext cx=\"" + std::to_string(imgW) + "\" cy=\"" + std::to_string(imgH) + "\"/>"
                    "</a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
                    "</pic:pic></a:graphicData></a:graphic>"
                    "</wp:inline></w:drawing></w:r></w:p>";
                nextImageIdx++;
            }
        }
    }

    // Section properties
    documentXml +=
        "<w:sectPr>"
        "<w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
        "<w:pgMar w:top=\"1440\" w:right=\"1800\" w:bottom=\"1440\" w:left=\"1800\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/>"
        "</w:sectPr>"
        "</w:body></w:document>";

    docxFiles.push_back({"word/document.xml", std::vector<uint8_t>(documentXml.begin(), documentXml.end())});
    docxFiles.push_back({"word/_rels/document.xml.rels", std::vector<uint8_t>(docRels.begin(), docRels.end())});

    // Step 8: Create ZIP output
    if (!createZIP(outputPath, docxFiles)) {
        result.errorMsg = "Failed to create ZIP output";
        return false;
    }

    result.success = true;
    result.outputPath = outputPath;
    result.pageCount = paraCount + tableCount;
    OH_LOG_INFO(LOG_APP, "DOC: Conversion successful, %{public}d paragraphs, %{public}d tables, %{public}d images, output=%{public}s",
                paraCount, tableCount, (int)images.size(), outputPath.c_str());
    return true;
}

// ============================================================================
// PPT Conversion (PowerPoint 97-2003 Binary Format)
// ============================================================================

// PowerPoint Record Types (per MS-PPT specification)
// Record header: 8 bytes = recType(2) + recLen(4) + version/instance(2)
// Container detection: first byte AND 0x0F == 0x0F means container

enum PPTRecordType {
    PPT_RT_DOCUMENT = 1000,      // 0x03E8 - Document container
    PPT_RT_DOCUMENT_ATOM = 1001, // 0x03E9 - Document atom (slide size)
    PPT_RT_SLIDE = 1006,         // 0x03EE - Slide container
    PPT_RT_SLIDE_ATOM = 1007,    // 0x03EF - Slide atom
    PPT_RT_NOTES = 1009,         // 0x03F1 - Notes container
    PPT_RT_MAIN_MASTER = 1017,   // 0x03F9 - Main master container
    PPT_RT_SLIDE_PERSIST_ATOM = 1011, // 0x03F3 - Slide persistence
    PPT_RT_PPDRAWING = 1036,     // 0x040C - PowerPoint drawing (Escher)
    PPT_RT_TEXT_HEADER_ATOM = 3999, // 0x0F9F - Text header (preceding text)
    PPT_RT_TEXT_CHARS_ATOM = 4000,  // 0x0FA0 - UTF-16 text content
    PPT_RT_TEXT_BYTES_ATOM = 4008,  // 0x0FA8 - ASCII text content
    PPT_RT_SLIDE_LIST_WITH_TEXT = 4080, // 0x0FF0 - Slide list (corrected)
    PPT_RT_USER_EDIT_ATOM = 4085,    // 0x0FF5 - User edit info
    PPT_RT_CURRENT_USER_ATOM = 4086, // 0x0FF6 - Current user (in Current User stream)
    // Escher/DrawingML containers (high record types)
    PPT_RT_SHAPE_CONTAINER = 61442,  // 0xF006 - Shape container (Escher)
    PPT_RT_GROUPSHAPE_CONTAINER = 61443, // 0xF007 - Group shape container
};

// Escher record types (MS-ODRAW and MS-PPT)
static constexpr uint16_t ESCHER_FOPT = 0xF00B;             // Primary property table (OfficeArtFOPT)
static constexpr uint16_t ESCHER_CLIENT_TEXTBOX = 0xF00D;    // Client textbox container
static constexpr uint16_t ESCHER_CLIENT_DATA = 0xF011;       // Client data container
static constexpr uint16_t ESCHER_CHILD_ANCHOR = 0xF010;      // OfficeArtClientAnchor (shape position per MS-PPT 2.7.1)
static constexpr uint16_t ESCHER_F122_OLEPACKAGE = 0xF122;   // Embedded OLE package (contains ZIP with image)

// Per MS-ODRAW spec, inside OfficeArtClientTextbox (0xF00D):
// Record types for text data within client textbox
static constexpr uint16_t ESCHER_TXBX_TEXT_DATA = 0x0FA0;    // Text content (UTF-16LE) in OfficeArtClientTextbox

// Per MS-PPT spec section 2.4.2 (DocumentAtom):
// slideSize is in master units. 1 master unit = 1/576 inch = 914400/576 EMU
// Use exact formula: (int32_t)((int64_t)masterUnits * 914400 / 576)

// Global slide dimensions read from DocumentAtom (in EMU)
static int32_t g_slideWidthEmu = 12192000;   // Default widescreen 16:9
static int32_t g_slideHeightEmu = 6858000;

// Escher property IDs (MS-ODRAW) - extended for full shape parsing
static constexpr uint16_t ESCHER_PROP_pib = 0x0004;            // BLIP reference ID (PICTURE SHAPE!)
static constexpr uint16_t ESCHER_PROP_lTxid = 0x0080;          // Text ID (simple property)
static constexpr uint16_t ESCHER_PROP_fillColor = 0x0180;      // Fill color (RGB)
static constexpr uint16_t ESCHER_PROP_lineColor = 0x0190;      // Line color (RGB)
static constexpr uint16_t ESCHER_PROP_lineWidth = 0x01D0;      // Line width (EMU)
static constexpr uint16_t ESCHER_PROP_wzName = 0x0380;         // Shape name (complex, UTF-16LE)
static constexpr uint16_t ESCHER_PROP_wzDescription = 0x0381;  // Alt text/description (complex, UTF-16LE)
static constexpr uint16_t ESCHER_PROP_gtextUNICODE = 0x03E0;   // WordArt text (complex, UTF-16LE)

// ============================================================================
// Enhanced Shape Data Structures for complete PPTX generation
// ============================================================================

// Shape position/size in EMU (English Metric Units)
struct ShapeTransform {
    int32_t x;      // Left position (EMU)
    int32_t y;      // Top position (EMU)
    int32_t cx;     // Width (EMU)
    int32_t cy;     // Height (EMU)

    ShapeTransform() : x(0), y(0), cx(9144000), cy(6858000) {}  // Default to slide size
};

// Shape visual style
struct ShapeStyle {
    uint32_t fillColor;    // Fill color RGB (0xFFFFFFFF = no fill)
    uint32_t lineColor;    // Line color RGB
    int32_t lineWidth;     // Line width in EMU
    bool hasFill;
    bool hasLine;

    ShapeStyle() : fillColor(0xFFFFFFFF), lineColor(0), lineWidth(12700),
                   hasFill(false), hasLine(false) {}
};

// Image reference within PPT
struct ImageReference {
    uint32_t persistId;    // Persist ID from Escher pib property
    uint16_t blipIndex;    // Index in images vector (resolved later)
    bool hasImage;
    bool isEmbedded;       // True if image is from F122 embedded OLE package
    std::vector<uint8_t> embeddedData;  // Direct embedded image data (from F122)
    size_t embeddedIdx;    // Assigned index in embeddedImages vector (for PPTX generation)

    ImageReference() : persistId(0), blipIndex(0), hasImage(false), isEmbedded(false), embeddedIdx(0) {}
};

// Text formatting for PPTX generation
struct TextFormat {
    int32_t fontSize;       // Font size in hundredths of a point (e.g., 3600 = 36pt)
    bool isBold;            // Bold text
    uint32_t textColor;     // Text color RGB (0xRRGGBB)
    bool hasTextColor;      // Whether text color is explicitly set
    bool hasExplicitSize;   // Whether font size was parsed from PPT binary
    std::string fontName;   // Font typeface name

    TextFormat() : fontSize(1800), isBold(false), textColor(0x000000),
                   hasTextColor(false), hasExplicitSize(false), fontName("SimHei") {}
};

// Complete shape data
struct ShapeData {
    int shapeId;                    // Unique shape ID (for PPTX id attribute)
    std::string text;               // Display text content (UTF-8) - only from 0xF00D/0x0FA0
    std::string shapeName;          // Shape name from wzName (e.g. "AutoShape 3", "Connector 2")
    ShapeTransform transform;       // Position and size
    ShapeStyle style;               // Visual style
    ImageReference imageRef;        // Image reference (if picture shape)
    TextFormat textFmt;             // Text formatting info
    bool isTextShape;               // Has actual display text (from 0xF00D/0x0FA0)
    bool isPictureShape;            // Contains image
    bool isConnector;               // Is a connector/line shape
    bool hasTextbox;                // Has 0xF00D OfficeArtClientTextbox

    ShapeData() : shapeId(0), text(""), shapeName(""), isTextShape(false),
                  isPictureShape(false), isConnector(false), hasTextbox(false) {}
};

// Enhanced slide data with complete shape information
struct PPTSlideDataEnhanced {
    int slideIndex;
    std::vector<ShapeData> shapes;

    // Helper: get text shapes
    std::vector<const ShapeData*> getTextShapes() const {
        std::vector<const ShapeData*> result;
        for (const auto& s : shapes) {
            if (s.isTextShape && !s.text.empty()) result.push_back(&s);
        }
        return result;
    }

    // Helper: get picture shapes
    std::vector<const ShapeData*> getPictureShapes() const {
        std::vector<const ShapeData*> result;
        for (const auto& s : shapes) {
            if (s.isPictureShape && s.imageRef.hasImage) result.push_back(&s);
        }
        return result;
    }
};

// PPT Slide structure for conversion
struct PPTSlideData {
    int slideIndex;
    std::string title;
    std::vector<std::string> textContent;
    std::vector<uint8_t> imageData;  // Embedded image if any
};

// Read PPT record header: recType(2) + recLen(4) at offset
static bool readPPTRecordHeader(const uint8_t* data, size_t offset, size_t maxLen,
                                 uint16_t& recType, uint32_t& recLen) {
    // Safety check: need at least 8 bytes for header
    if (offset + 8 > maxLen) return false;

    // PPT Atom record format (MS-PPT):
    // offset+0-1: recVer (4 bits) + recInstance (12 bits)
    // offset+2-3: recType
    // offset+4-7: recLen (4 bytes)
    recType = data[offset + 2] | (data[offset + 3] << 8);
    recLen = data[offset + 4] | (data[offset + 5] << 8) |
             (data[offset + 6] << 16) | (data[offset + 7] << 24);

    // Additional safety: validate recLen doesn't exceed remaining space
    // Some containers have len=8 (just header), meaning recLen should be 0
    size_t remainingSpace = maxLen - offset;
    if (recLen > remainingSpace - 8) {
        // Adjust recLen to fit within bounds (for container records)
        // Note: Containers have recLen = container length - 8 (header size)
        // But atom records have recLen = data length
        OH_LOG_WARN(LOG_APP, "PPT: recLen %{public}d exceeds remaining %{public}d bytes at %{public}d, adjusting",
                    (int)recLen, (int)(remainingSpace - 8), (int)offset);
        recLen = remainingSpace - 8;
    }

    return true;
}

// Escher BLIP types (from Pictures stream)
enum EscherBlipType {
    BLIP_PNG = 0x6E,
    BLIP_JPEG = 0x6D,
    BLIP_WMF = 0x6A,
    BLIP_EMF = 0x6C,
    BLIP_PICT = 0x6B,
    BLIP_DIB = 0x6F
};

// Parse Pictures stream to extract all BLIP images
static std::vector<BlipImage> parsePicturesStream(const uint8_t* data, size_t size) {
    std::vector<BlipImage> images;
    size_t pos = 0;

    OH_LOG_INFO(LOG_APP, "PPT: Parsing Pictures stream, size=%{public}d", (int)size);

    // Scan for Escher BLIP records (type 0xF01E = msofbtBlip)
    while (pos + 25 < size) {
        // Escher record header: instance(2) + type(2) + length(4)
        uint16_t instance = data[pos] | (data[pos + 1] << 8);
        uint16_t recType = data[pos + 2] | (data[pos + 3] << 8);
        uint32_t dataLen = data[pos + 4] | (data[pos + 5] << 8) |
                          (data[pos + 6] << 16) | (data[pos + 7] << 24);

        // Check for msofbtBlip (0xF01E)
        if (recType == 0xF01E) {
            // BLIP type is in the high bits of instance (bits 12-15)
            uint16_t blipType = (instance >> 4) & 0x0F;

            // Map to standard type codes
            uint16_t imgType = 0;
            switch (blipType) {
                case 5: imgType = BLIP_JPEG; break;   // msoblipJPEG
                case 6: imgType = BLIP_PNG; break;    // msoblipPNG
                case 3: imgType = BLIP_WMF; break;    // msoblipWMF
                case 4: imgType = BLIP_EMF; break;    // msoblipEMF
                default: imgType = BLIP_PNG; break;   // Default to PNG
            }

            // Image data starts at pos + 8 (header) + 17 (BLIP header)
            // Actual image length is dataLen - 17 (BLIP header size)
            if (pos + 25 < size && dataLen > 17) {
                BlipImage img;
                img.type = imgType;
                img.index = images.size();

                // Extract image data (skip 8-byte record header + 17-byte BLIP header)
                size_t imgStart = pos + 25;
                size_t imgSize = dataLen - 17;
                if (imgStart + imgSize <= size) {
                    img.data.assign(data + imgStart, data + imgStart + imgSize);
                    images.push_back(img);

                    OH_LOG_INFO(LOG_APP, "PPT: Found BLIP %{public}d, type=%{public}d(0x%{public}02X), size=%{public}d",
                                (int)img.index, (int)img.type, img.type, (int)imgSize);
                }
            }

            pos += 8 + dataLen;
        } else if (recType >= 0xF000) {
            // Other Escher container - skip it
            pos += 8 + dataLen;
        } else {
            // Not an Escher record - try to find next BLIP
            // Look for PNG signature (89 50 4E 47) or JPEG signature (FF D8 FF)
            pos++;
        }
    }

    OH_LOG_INFO(LOG_APP, "PPT: Total images extracted: %{public}d", (int)images.size());
    return images;
}

// Extract embedded image from F122 OLE package (ZIP containing image in drs/media/image1.png)
// Returns true if image was found and extracted
static bool extractF122EmbeddedImage(const uint8_t* data, size_t len, std::vector<uint8_t>& imgData) {
    // F122 contains an embedded OLE package which is a ZIP file
    // The ZIP contains the image in drs/media/image1.png

    // Find ZIP local file header signature: PK\x03\x04 = 50 4B 03 04
    const uint8_t zipSig[] = {0x50, 0x4B, 0x03, 0x04};
    size_t zipOffset = 0;

    for (size_t i = 0; i + 4 <= len; i++) {
        if (data[i] == zipSig[0] && data[i+1] == zipSig[1] &&
            data[i+2] == zipSig[2] && data[i+3] == zipSig[3]) {
            zipOffset = i;
            break;
        }
    }

    if (zipOffset == 0 || zipOffset + 30 > len) {
        return false;  // No ZIP signature found
    }

    // Parse ZIP local file headers to find image file
    size_t pos = zipOffset;
    while (pos + 30 <= len) {
        // Check for local file header signature
        if (data[pos] != 0x50 || data[pos+1] != 0x4B || data[pos+2] != 0x03 || data[pos+3] != 0x04) {
            break;  // End of local file headers
        }

        // Local file header structure:
        // 0-3: signature (PK\x03\x04)
        // 4-5: version needed
        // 6-7: general purpose bit flag
        // 8-9: compression method (0 = stored, 8 = deflate)
        // 10-11: file modification time
        // 12-13: file modification date
        // 14-17: CRC-32
        // 18-21: compressed size
        // 22-25: uncompressed size
        // 26-27: file name length
        // 28-29: extra field length

        uint16_t compMethod = data[pos + 8] | (data[pos + 9] << 8);
        uint32_t compSize = data[pos + 18] | (data[pos + 19] << 8) |
                            (data[pos + 20] << 16) | (data[pos + 21] << 24);
        uint32_t uncompSize = data[pos + 22] | (data[pos + 23] << 8) |
                              (data[pos + 24] << 16) | (data[pos + 25] << 24);
        uint16_t nameLen = data[pos + 26] | (data[pos + 27] << 8);
        uint16_t extraLen = data[pos + 28] | (data[pos + 29] << 8);

        // Get file name
        if (pos + 30 + nameLen > len) break;
        std::string fileName(reinterpret_cast<const char*>(data + pos + 30), nameLen);

        // Check if this is the image file (drs/media/image1.png or similar)
        if (fileName.find("media/image") != std::string::npos &&
            (fileName.find(".png") != std::string::npos || fileName.find(".jpg") != std::string::npos)) {

            size_t dataOffset = pos + 30 + nameLen + extraLen;

            if (dataOffset + compSize > len) break;

            // If stored (no compression), just copy the data
            if (compMethod == 0) {
                imgData.assign(data + dataOffset, data + dataOffset + compSize);
                OH_LOG_INFO(LOG_APP, "PPT: Found embedded image '%{public}s', size=%{public}d (stored)",
                            fileName.c_str(), (int)compSize);
                return true;
            }

            // For deflate compression, use zlib to decompress
            if (compMethod == 8) {
                if (uncompSize == 0 || uncompSize > 5000000) {
                    OH_LOG_WARN(LOG_APP, "PPT: Image '%{public}s' bad uncompSize=%{public}d",
                                fileName.c_str(), (int)uncompSize);
                    pos += 30 + nameLen + extraLen + compSize;
                    continue;
                }

                imgData.resize(uncompSize);
                z_stream strm = {};
                strm.next_in = const_cast<uint8_t*>(data + dataOffset);
                strm.avail_in = compSize;
                strm.next_out = imgData.data();
                strm.avail_out = uncompSize;

                int ret = inflateInit2(&strm, -15);  // raw deflate
                if (ret != Z_OK) {
                    OH_LOG_WARN(LOG_APP, "PPT: Image inflateInit2 failed, ret=%{public}d", ret);
                    pos += 30 + nameLen + extraLen + compSize;
                    continue;
                }

                ret = inflate(&strm, Z_FINISH);
                inflateEnd(&strm);

                if (ret != Z_STREAM_END) {
                    OH_LOG_WARN(LOG_APP, "PPT: Image inflate failed, ret=%{public}d", ret);
                    pos += 30 + nameLen + extraLen + compSize;
                    continue;
                }

                imgData.resize(strm.total_out);
                OH_LOG_INFO(LOG_APP, "PPT: Inflated image '%{public}s', comp=%{public}d -> uncomp=%{public}d",
                            fileName.c_str(), (int)compSize, (int)strm.total_out);
                return true;
            }
        }

        // Move to next local file header
        pos += 30 + nameLen + extraLen + compSize;
    }

    return false;
}

// Helper: extract <a:t> text from XML data (UTF-8)
static std::string extractATTagsFromXml(const uint8_t* xmlData, size_t xmlLen) {
    std::string result;
    size_t searchPos = 0;

    while (searchPos + 10 < xmlLen) {
        // Find <a:t>
        const uint8_t* found = nullptr;
        for (size_t sp = searchPos; sp + 4 < xmlLen; sp++) {
            if (xmlData[sp] == '<' && xmlData[sp+1] == 'a' && xmlData[sp+2] == ':' &&
                xmlData[sp+3] == 't' && xmlData[sp+4] == '>') {
                found = xmlData + sp + 5;
                searchPos = sp + 5;
                break;
            }
        }
        if (!found) break;

        // Find </a:t>
        const uint8_t* endTag = nullptr;
        for (size_t ep = searchPos; ep + 5 < xmlLen; ep++) {
            if (xmlData[ep] == '<' && xmlData[ep+1] == '/' && xmlData[ep+2] == 'a' &&
                xmlData[ep+3] == ':' && xmlData[ep+4] == 't' && xmlData[ep+5] == '>') {
                endTag = xmlData + ep;
                searchPos = ep + 6;
                break;
            }
        }
        if (!endTag) break;

        size_t textLen = endTag - found;
        if (textLen > 0 && textLen < 5000) {
            std::string text(reinterpret_cast<const char*>(found), textLen);
            // Decode XML entities
            size_t ampPos = 0;
            while ((ampPos = text.find("&amp;")) != std::string::npos)
                text.replace(ampPos, 5, "&");
            while ((ampPos = text.find("&lt;")) != std::string::npos)
                text.replace(ampPos, 4, "<");
            while ((ampPos = text.find("&gt;")) != std::string::npos)
                text.replace(ampPos, 4, ">");
            while ((ampPos = text.find("&quot;")) != std::string::npos)
                text.replace(ampPos, 6, "\"");

            if (!result.empty()) result += "\n";
            result += text;
        }
    }
    return result;
}

// Extract text from shapexml.xml inside F122 OLE package (inst=2 shapes)
// The ZIP contains drs/shapexml.xml which has DrawingML with <a:t> text elements
// Uses zlib inflate for deflate-compressed entries
static std::string extractF122ShapeXmlText(const uint8_t* data, size_t len) {
    // Find ZIP local file header signature: PK\x03\x04
    const uint8_t zipSig[] = {0x50, 0x4B, 0x03, 0x04};
    size_t zipOffset = 0;

    for (size_t i = 0; i + 4 <= len; i++) {
        if (data[i] == zipSig[0] && data[i+1] == zipSig[1] &&
            data[i+2] == zipSig[2] && data[i+3] == zipSig[3]) {
            zipOffset = i;
            break;
        }
    }

    if (zipOffset == 0 || zipOffset + 30 > len) {
        return "";
    }

    // Parse ZIP local file headers to find shapexml.xml
    size_t pos = zipOffset;
    while (pos + 30 <= len) {
        if (data[pos] != 0x50 || data[pos+1] != 0x4B || data[pos+2] != 0x03 || data[pos+3] != 0x04) {
            break;
        }

        uint16_t compMethod = data[pos + 8] | (data[pos + 9] << 8);
        uint32_t compSize = data[pos + 18] | (data[pos + 19] << 8) |
                            (data[pos + 20] << 16) | (data[pos + 21] << 24);
        uint32_t uncompSize = data[pos + 22] | (data[pos + 23] << 8) |
                              (data[pos + 24] << 16) | (data[pos + 25] << 24);
        uint16_t nameLen = data[pos + 26] | (data[pos + 27] << 8);
        uint16_t extraLen = data[pos + 28] | (data[pos + 29] << 8);

        if (pos + 30 + nameLen > len) break;
        std::string fileName(reinterpret_cast<const char*>(data + pos + 30), nameLen);

        // Look for shapexml.xml file
        if (fileName.find("shapexml") != std::string::npos && fileName.find(".xml") != std::string::npos) {
            size_t dataOffset = pos + 30 + nameLen + extraLen;
            if (dataOffset + compSize > len) break;

            const uint8_t* compData = data + dataOffset;
            size_t xmlLen = 0;
            std::vector<uint8_t> decompressed;

            if (compMethod == 0) {
                // Stored (no compression)
                xmlLen = compSize;
                OH_LOG_INFO(LOG_APP, "PPT: shapexml.xml stored, size=%{public}d", (int)compSize);
            } else if (compMethod == 8) {
                // Deflate compressed - use zlib inflate
                // ZIP uses raw deflate (no zlib/gzip header), windowBits = -15
                if (uncompSize == 0 || uncompSize > 1000000) {
                    OH_LOG_WARN(LOG_APP, "PPT: shapexml.xml bad uncompSize=%{public}d", (int)uncompSize);
                    pos += 30 + nameLen + extraLen + compSize;
                    continue;
                }

                decompressed.resize(uncompSize);
                z_stream strm = {};
                strm.next_in = const_cast<uint8_t*>(compData);
                strm.avail_in = compSize;
                strm.next_out = decompressed.data();
                strm.avail_out = uncompSize;

                int ret = inflateInit2(&strm, -15);  // raw deflate
                if (ret != Z_OK) {
                    OH_LOG_WARN(LOG_APP, "PPT: inflateInit2 failed, ret=%{public}d", ret);
                    pos += 30 + nameLen + extraLen + compSize;
                    continue;
                }

                ret = inflate(&strm, Z_FINISH);
                inflateEnd(&strm);

                if (ret != Z_STREAM_END) {
                    OH_LOG_WARN(LOG_APP, "PPT: inflate failed, ret=%{public}d", ret);
                    pos += 30 + nameLen + extraLen + compSize;
                    continue;
                }

                xmlLen = strm.total_out;
                OH_LOG_INFO(LOG_APP, "PPT: shapexml.xml inflated, compSize=%{public}d -> uncompSize=%{public}d",
                            (int)compSize, (int)xmlLen);
            } else {
                OH_LOG_WARN(LOG_APP, "PPT: shapexml.xml unknown compression method=%{public}d", compMethod);
                pos += 30 + nameLen + extraLen + compSize;
                continue;
            }

            const uint8_t* xmlData = (compMethod == 0) ? compData : decompressed.data();
            std::string result = extractATTagsFromXml(xmlData, xmlLen);

            if (!result.empty()) {
                OH_LOG_INFO(LOG_APP, "PPT: Extracted text from shapexml.xml: '%{public}s'",
                            result.substr(0, 80).c_str());
            }
            return result;
        }

        pos += 30 + nameLen + extraLen + compSize;
    }

    return "";
}

// Check if record is a container based on MS-PPT specification
// Per MS-PPT spec: Container is identified by recVer == 0xF in the record header
// PPT-defined containers have specific recType values defined in the spec
// Escher containers have recVer == 0xF (NOT just recType >= 0xF000)
static bool isPPTContainer(uint16_t recType, uint8_t recVer) {
    // PPT-defined containers (explicitly specified in MS-PPT as container record types)
    switch (recType) {
        case PPT_RT_DOCUMENT:        // 1000 - Document container
        case PPT_RT_SLIDE:           // 1006 - Slide container
        case PPT_RT_NOTES:           // 1009 - Notes container
        case PPT_RT_MAIN_MASTER:     // 1017 - Main master
        case PPT_RT_PPDRAWING:       // 1036 - PowerPoint drawing
        case PPT_RT_SLIDE_LIST_WITH_TEXT: // 4080 - Slide list
            return true;
        default:
            break;
    }
    // Escher containers: per MS-ODRAW spec, identified by recVer == 0xF
    // This correctly distinguishes Escher containers from Escher atoms
    // (both have recType >= 0xF000, but only containers have recVer == 0xF)
    if (recVer == 0x0F) return true;
    return false;
}

// Parse CurrentUserAtom to get offset to latest UserEditAtom
static uint32_t parseCurrentUserAtom(const uint8_t* data, size_t size) {
    // CurrentUserAtom structure per MS-PPT:
    // Offset 0-7: Record header (recType=0x0FF6, recLen)
    // Offset 8-11: size (4 bytes) - should be 0x14 for basic
    // Offset 12-15: headerToken (4 bytes)
    // Offset 16-19: offsetToCurrentEdit (4 bytes) - KEY: offset to UserEditAtom
    // Offset 20-23: lenUserName (4 bytes)
    // ...

    if (size < 24) {
        OH_LOG_WARN(LOG_APP, "PPT: CurrentUserAtom too small: %{public}d", (int)size);
        return 0;
    }

    // Check record type
    uint16_t recType = data[0] | (data[1] << 8);
    if (recType != PPT_RT_CURRENT_USER_ATOM) {
        OH_LOG_WARN(LOG_APP, "PPT: CurrentUserAtom wrong type: 0x%{public}04X", recType);
        return 0;
    }

    // Read offsetToCurrentEdit at byte 16 (after 8-byte header + 4-byte size + 4-byte headerToken)
    uint32_t offsetToCurrentEdit = data[16] | (data[17] << 8) |
                                   (data[18] << 16) | (data[19] << 24);

    OH_LOG_INFO(LOG_APP, "PPT: CurrentUserAtom offsetToCurrentEdit=%{public}d", (int)offsetToCurrentEdit);
    return offsetToCurrentEdit;
}

// Parse UserEditAtom to get offset to Document Container
static uint32_t parseUserEditAtom(const uint8_t* data, size_t offset, size_t maxLen) {
    // UserEditAtom structure per MS-PPT:
    // Offset 0-7: Record header (recType=0x0FF5)
    // Offset 8-11: lastSlideId (4 bytes)
    // Offset 12-15: penColor (4 bytes)
    // Offset 16-19: offsetToPersist (4 bytes) - offset to PersistPtrIncrementalBlock
    // Offset 20-23: offsetToDocPersistIdRef (4 bytes)
    // Offset 24-27: persistId (4 bytes)
    // Offset 28-31: persistRefCount (4 bytes)
    // Offset 32-35: docPersistIdRef (4 bytes) - reference to Document Container
    // Offset 36-39: offsetToNextUserEdit (4 bytes) - offset to previous UserEditAtom (chain)

    if (offset + 40 > maxLen) return 0;

    uint16_t recType = data[offset] | (data[offset + 1] << 8);
    if (recType != PPT_RT_USER_EDIT_ATOM) {
        OH_LOG_WARN(LOG_APP, "PPT: UserEditAtom wrong type at %{public}d: 0x%{public}04X", (int)offset, recType);
        return 0;
    }

    // Read docPersistIdRef at offset + 32
    uint32_t docPersistIdRef = data[offset + 32] | (data[offset + 33] << 8) |
                               (data[offset + 34] << 16) | (data[offset + 35] << 24);

    OH_LOG_INFO(LOG_APP, "PPT: UserEditAtom docPersistIdRef=%{public}d", (int)docPersistIdRef);

    // Also read offsetToNextUserEdit (previous edit) for chain traversal
    uint32_t offsetToNext = data[offset + 36] | (data[offset + 37] << 8) |
                            (data[offset + 38] << 16) | (data[offset + 39] << 24);

    // For simplicity, we use the docPersistIdRef as offset to Document Container
    // Note: In full implementation, this is a persistence ID that needs to be resolved
    // via PersistPtrIncrementalBlock, but for many files, it directly maps to offset

    return docPersistIdRef;
}

// ============================================================================
// Enhanced Escher Parsing for Shape Properties
// ============================================================================

// Parse OfficeArtClientAnchor (0xF010) to get shape position
// Per MS-PPT specification section 2.7.1-2.7.2:
//   rh.recLen = 0x00000008 -> SmallRectStruct (top, left, right, bottom as 2-byte signed integers)
//   rh.recLen = 0x00000010 -> RectStruct (top, left, right, bottom as 4-byte signed integers)
// Note: Order is top, left, right, bottom (NOT left, top, right, bottom!)
// Values are in PPT units (points/slide coordinates), need conversion to EMU
static void parseChildAnchor(const uint8_t* data, size_t len, ShapeTransform& transform, uint16_t recType) {
    OH_LOG_INFO(LOG_APP, "PPT: Parsing OfficeArtClientAnchor type 0x%{public}04X, len=%{public}d", recType, (int)len);

    if (recType != ESCHER_CHILD_ANCHOR) {
        OH_LOG_WARN(LOG_APP, "PPT: Not a ClientAnchor record, using defaults");
        return;
    }

    if (len == 8) {
        // SmallRectStruct: top, left, right, bottom as int16
        // Order per MS-PPT: top, left, right, bottom
        int16_t top = (int16_t)(data[0] | (data[1] << 8));
        int16_t left = (int16_t)(data[2] | (data[3] << 8));
        int16_t right = (int16_t)(data[4] | (data[5] << 8));
        int16_t bottom = (int16_t)(data[6] | (data[7] << 8));

        // Convert from PPT units to EMU
        // SmallRectStruct uses "master units" which are 1/576 inch
        // EMU = 914400 per inch, so 1 master unit = 914400/576 EMU
        // Use exact integer math: EMU = masterUnits * 914400 / 576
        // To avoid overflow: masterUnits are int16 (max ~32767), so max value = 32767 * 914400 / 576 ≈ 52M
        // Safe to compute as: (int32_t)((int64_t)val * 914400 / 576)
        auto masterToEmu = [](int16_t val) -> int32_t {
            return (int32_t)((int64_t)val * 914400 / 576);
        };
        transform.x = masterToEmu(left);
        transform.y = masterToEmu(top);
        transform.cx = masterToEmu(right) - masterToEmu(left);
        transform.cy = masterToEmu(bottom) - masterToEmu(top);

        OH_LOG_INFO(LOG_APP, "PPT: SmallRectStruct top=%{public}d, left=%{public}d, right=%{public}d, bottom=%{public}d (master units)",
                    (int)top, (int)left, (int)right, (int)bottom);
        OH_LOG_INFO(LOG_APP, "PPT: Converted to EMU: x=%{public}d, y=%{public}d, cx=%{public}d, cy=%{public}d",
                    (int)transform.x, (int)transform.y, (int)transform.cx, (int)transform.cy);

    } else if (len == 16) {
        // RectStruct: top, left, right, bottom as int32
        // Order per MS-PPT: top, left, right, bottom
        int32_t top = (int32_t)(data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24));
        int32_t left = (int32_t)(data[4] | (data[5] << 8) | (data[6] << 16) | (data[7] << 24));
        int32_t right = (int32_t)(data[8] | (data[9] << 8) | (data[10] << 16) | (data[11] << 24));
        int32_t bottom = (int32_t)(data[12] | (data[13] << 8) | (data[14] << 16) | (data[15] << 24));

        // These values are already in EMU (English Metric Units)
        transform.x = left;
        transform.y = top;
        transform.cx = right - left;
        transform.cy = bottom - top;

        OH_LOG_INFO(LOG_APP, "PPT: RectStruct top=%{public}d, left=%{public}d, right=%{public}d, bottom=%{public}d (EMU)",
                    (int)top, (int)left, (int)right, (int)bottom);

    } else {
        OH_LOG_WARN(LOG_APP, "PPT: Invalid ClientAnchor length %{public}d, using defaults", (int)len);
        transform.x = 457200;
        transform.y = 914400;
        transform.cx = 8229600;
        transform.cy = 457200;
    }
}

// Parse OfficeArtFOPT (0xF00B) to extract ALL properties into ShapeData
// Enhanced version that extracts position, style, and image references
static void parseEscherFOPTEnhanced(const uint8_t* data, size_t len, uint16_t propCount, ShapeData& shape) {
    // Each FOPTE entry is 6 bytes: opid(2) + op(4)
    size_t fixedArraySize = (size_t)propCount * 6;
    if (fixedArraySize > len) {
        OH_LOG_WARN(LOG_APP, "PPT: FOPT array too large: %{public}d props, len=%{public}d",
                    (int)propCount, (int)len);
        return;
    }

    // Collect complex properties for second pass
    struct ComplexPropInfo {
        uint16_t propid;
        uint32_t dataSize;
    };
    std::vector<ComplexPropInfo> complexProps;
    size_t complexDataOffset = 0;

    // First pass: extract simple properties and record complex ones
    for (uint16_t i = 0; i < propCount; i++) {
        size_t entryOffset = (size_t)i * 6;
        uint16_t opidRaw = data[entryOffset] | (data[entryOffset + 1] << 8);
        uint32_t op = data[entryOffset + 2] | (data[entryOffset + 3] << 8) |
                     (data[entryOffset + 4] << 16) | (data[entryOffset + 5] << 24);

        bool fComplex = (opidRaw >> 15) & 1;
        uint16_t propid = opidRaw & 0x3FFF;

        if (!fComplex) {
            // Simple property - value is directly in op
            switch (propid) {
                case ESCHER_PROP_pib:  // 0x0004 - BLIP reference ID (IMAGE!)
                    shape.imageRef.persistId = op;
                    shape.imageRef.hasImage = (op > 0 && op < 1000);  // Valid PersistId range
                    shape.isPictureShape = (op > 0 && op < 1000);
                    OH_LOG_INFO(LOG_APP, "PPT: Found pib=%{public}u (0x%{public}08X), propid=0x%{public}04X, opidRaw=0x%{public}04X",
                                op, op, propid, opidRaw);
                    break;

                case ESCHER_PROP_fillColor:  // 0x0180
                    shape.style.fillColor = op;
                    shape.style.hasFill = true;
                    OH_LOG_INFO(LOG_APP, "PPT: Found fillColor=0x%{public}06X", op);
                    break;

                case ESCHER_PROP_lineColor:  // 0x0190
                    shape.style.lineColor = op;
                    shape.style.hasLine = true;
                    break;

                case ESCHER_PROP_lineWidth:  // 0x01D0
                    shape.style.lineWidth = op;
                    break;
            }
        } else {
            // Complex property - op is the byte count
            complexProps.push_back({propid, op});
            complexDataOffset += op;
        }
    }

    // Second pass: extract complex property data
    size_t complexDataStart = fixedArraySize;
    size_t currentOffset = 0;

    for (const auto& cp : complexProps) {
        if (complexDataStart + currentOffset + cp.dataSize > len) continue;

        const uint8_t* propData = data + complexDataStart + currentOffset;

        // wzName property - store as shapeName (NOT display text!)
        // Per MS-ODRAW spec: wzName is the shape's internal name like "AutoShape 3", "Connector 2"
        // This is NOT the text displayed on the shape.
        if (cp.propid == ESCHER_PROP_wzName && cp.dataSize > 0 && cp.dataSize < 5000) {
            std::string decoded;
            for (size_t i = 0; i + 1 < cp.dataSize; i += 2) {
                uint16_t ch = propData[i] | (propData[i + 1] << 8);
                if (ch == 0) continue;
                if (ch < 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D) continue;
                if (ch < 0x80) decoded += (char)ch;
                else if (ch < 0x800) {
                    decoded += (char)(0xC0 | (ch >> 6));
                    decoded += (char)(0x80 | (ch & 0x3F));
                } else {
                    decoded += (char)(0xE0 | (ch >> 12));
                    decoded += (char)(0x80 | ((ch >> 6) & 0x3F));
                    decoded += (char)(0x80 | (ch & 0x3F));
                }
            }
            if (!decoded.empty()) {
                shape.shapeName = decoded;

                // Detect connector shapes by name pattern
                if (decoded.find("Connector") != std::string::npos ||
                    decoded.find("Freeform") != std::string::npos ||
                    decoded.find("Line") != std::string::npos) {
                    shape.isConnector = true;
                }

                // Detect picture shapes by name (fallback when pib parsing fails)
                if (decoded.find("Picture") != std::string::npos || decoded.find("图片") != std::string::npos) {
                    size_t numStart = decoded.find_first_of("0123456789");
                    if (numStart != std::string::npos) {
                        uint16_t picNum = 0;
                        for (size_t i = numStart; i < decoded.size() && decoded[i] >= '0' && decoded[i] <= '9'; i++) {
                            picNum = picNum * 10 + (decoded[i] - '0');
                        }
                        if (picNum > 0 && picNum <= 100) {
                            shape.imageRef.blipIndex = picNum - 1;
                            shape.imageRef.hasImage = true;
                            shape.isPictureShape = true;
                            OH_LOG_INFO(LOG_APP, "PPT: Detected picture shape from name '%{public}s', blipIndex=%{public}d",
                                        decoded.c_str(), (int)shape.imageRef.blipIndex);
                        }
                    }
                }

                OH_LOG_INFO(LOG_APP, "PPT: FOPT wzName: '%{public}s', isConnector=%{public}d",
                            decoded.c_str(), (int)shape.isConnector);
            }
        }
        // gtextUNICODE - this IS display text (WordArt)
        else if (cp.propid == ESCHER_PROP_gtextUNICODE && cp.dataSize > 0 && cp.dataSize < 5000) {
            std::string text;
            for (size_t i = 0; i + 1 < cp.dataSize; i += 2) {
                uint16_t ch = propData[i] | (propData[i + 1] << 8);
                if (ch == 0 || (ch < 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D)) continue;
                if (ch < 0x80) text += (char)ch;
                else if (ch < 0x800) {
                    text += (char)(0xC0 | (ch >> 6));
                    text += (char)(0x80 | (ch & 0x3F));
                } else {
                    text += (char)(0xE0 | (ch >> 12));
                    text += (char)(0x80 | ((ch >> 6) & 0x3F));
                    text += (char)(0x80 | (ch & 0x3F));
                }
            }
            if (!text.empty()) {
                shape.text = text;
                shape.isTextShape = true;
                OH_LOG_INFO(LOG_APP, "PPT: FOPT gtextUNICODE: '%{public}s'", text.c_str());
            }
        }
        // wzDescription - alt text, not display text

        currentOffset += cp.dataSize;
    }
}

// Extract text from TextCharsAtom or TextBytesAtom
// data: pointer to the text atom data (starting at atom content, not including header)
// textLen: length of the text data (recLen from atom header)
static std::string extractPPTText(const uint8_t* data, uint16_t recType, uint32_t textLen) {
    std::string result;

    if (recType == PPT_RT_TEXT_CHARS_ATOM) {
        // UTF-16LE text: textLen bytes = character count * 2
        for (size_t i = 0; i + 1 < textLen; i += 2) {
            uint16_t ch = data[i] | (data[i + 1] << 8);
            if (ch == 0 || (ch < 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D)) continue;
            if (ch < 0x80) result += (char)ch;
            else if (ch < 0x800) {
                result += (char)(0xC0 | (ch >> 6));
                result += (char)(0x80 | (ch & 0x3F));
            } else {
                result += (char)(0xE0 | (ch >> 12));
                result += (char)(0x80 | ((ch >> 6) & 0x3F));
                result += (char)(0x80 | (ch & 0x3F));
            }
        }
    } else if (recType == PPT_RT_TEXT_BYTES_ATOM) {
        // ASCII text: textLen bytes directly
        for (size_t i = 0; i < textLen; i++) {
            uint8_t c = data[i];
            if (c == 0 || (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D)) continue;
            if (c < 0x80) result += (char)c;
            else {
                result += (char)(0xC0 | (c >> 6));
                result += (char)(0x80 | (c & 0x3F));
            }
        }
    }

    return result;
}

// Parse OfficeArtFOPT (0xF00B) record to extract text from Escher properties
// Per MS-ODRAW spec section 2.2.7-2.2.8:
//   - recInstance = property count N
//   - N entries of 6 bytes each: opid(2) + op(4)
//   - opid bit15 = fComplex (if set, op = byte count of trailing complex data)
//   - opid bits 0-13 = propid
//   - Complex data follows the fixed-size entry array, in same order as complex entries
// Parameters:
//   data: pointer to FOPT record content (after 8-byte record header)
//   len: length of record content (recLen)
//   propCount: number of properties (from recInstance field)
static std::vector<std::string> parseEscherFOPT(const uint8_t* data, size_t len, uint16_t propCount) {
    std::vector<std::string> texts;

    // Each FOPTE entry is 6 bytes
    size_t fixedArraySize = (size_t)propCount * 6;
    if (fixedArraySize > len) {
        OH_LOG_WARN(LOG_APP, "PPT: FOPT fixed array too large: %{public}d props * 6 = %{public}d, len=%{public}d",
                    (int)propCount, (int)fixedArraySize, (int)len);
        return texts;
    }

    // First pass: collect complex entries and their data offsets
    struct ComplexEntry {
        uint16_t propid;
        uint32_t dataSize;  // byte count from op field
    };
    std::vector<ComplexEntry> complexEntries;

    for (uint16_t i = 0; i < propCount; i++) {
        size_t entryOffset = (size_t)i * 6;
        uint16_t opidRaw = data[entryOffset] | (data[entryOffset + 1] << 8);
        uint32_t op = data[entryOffset + 2] | (data[entryOffset + 3] << 8) |
                     (data[entryOffset + 4] << 16) | (data[entryOffset + 5] << 24);

        bool fComplex = (opidRaw >> 15) & 1;
        uint16_t propid = opidRaw & 0x3FFF;

        if (fComplex) {
            // Check if this is a text-related property
            if (propid == ESCHER_PROP_wzName ||
                propid == ESCHER_PROP_wzDescription ||
                propid == ESCHER_PROP_gtextUNICODE) {
                complexEntries.push_back({propid, op});
            } else {
                // Non-text complex property - still need to track it to advance offset
                complexEntries.push_back({propid, op});
            }
        }
    }

    // Calculate complex data area start
    size_t complexDataStart = fixedArraySize;
    size_t complexDataEnd = len;

    // Second pass: extract text from complex entries
    size_t complexOffset = 0;
    for (const auto& entry : complexEntries) {
        if (complexOffset + entry.dataSize > complexDataEnd) {
            OH_LOG_WARN(LOG_APP, "PPT: FOPT complex data overflow at offset %{public}d, size=%{public}d, end=%{public}d",
                        (int)complexOffset, (int)entry.dataSize, (int)complexDataEnd);
            break;
        }

        // Extract text from text-related properties
        if ((entry.propid == ESCHER_PROP_wzName ||
             entry.propid == ESCHER_PROP_wzDescription ||
             entry.propid == ESCHER_PROP_gtextUNICODE) &&
            entry.dataSize > 0 && entry.dataSize < 5000) {
            const uint8_t* strData = data + complexDataStart + complexOffset;

            // Decode UTF-16LE to UTF-8
            std::string text;
            for (size_t i = 0; i + 1 < entry.dataSize; i += 2) {
                uint16_t ch = strData[i] | (strData[i + 1] << 8);
                if (ch == 0) continue;
                if (ch < 0x20 && ch != 0x09 && ch != 0x0A && ch != 0x0D) continue;
                if (ch < 0x80) {
                    text += (char)ch;
                } else if (ch < 0x800) {
                    text += (char)(0xC0 | (ch >> 6));
                    text += (char)(0x80 | (ch & 0x3F));
                } else {
                    text += (char)(0xE0 | (ch >> 12));
                    text += (char)(0x80 | ((ch >> 6) & 0x3F));
                    text += (char)(0x80 | (ch & 0x3F));
                }
            }

            if (!text.empty()) {
                texts.push_back(text);
                const char* propName = "unknown";
                if (entry.propid == ESCHER_PROP_wzName) propName = "wzName";
                else if (entry.propid == ESCHER_PROP_wzDescription) propName = "wzDescription";
                else if (entry.propid == ESCHER_PROP_gtextUNICODE) propName = "gtextUNICODE";
                OH_LOG_INFO(LOG_APP, "PPT: FOPT text prop %{public}s (size=%{public}d): '%{public}s'",
                            propName, (int)entry.dataSize, text.c_str());
            }
        }

        complexOffset += entry.dataSize;
    }

    return texts;
}

// Scan OfficeArtClientTextbox (0xF00D) container content for text data
// Per MS-PPT spec, inside 0xF00D are records like 0x0FA0 containing UTF-16LE text
static void scanClientTextboxContent(const uint8_t* data, size_t containerLen, ShapeData& shape) {
    size_t pos = 0;
    // First pass: collect text and StyleTextPropAtom locations
    size_t styleTextPropPos = 0;
    uint32_t styleTextPropLen = 0;

    while (pos + 8 <= containerLen) {
        uint8_t recVer = data[pos] & 0x0F;
        uint16_t recInstance = ((data[pos] >> 4) & 0x0F) | (data[pos + 1] << 4);
        uint16_t recType = data[pos + 2] | (data[pos + 3] << 8);
        uint32_t recLen = data[pos + 4] | (data[pos + 5] << 8) |
                         (data[pos + 6] << 16) | (data[pos + 7] << 24);

        if (recLen > containerLen - pos - 8 || recLen > 100000) {
            pos += 8;
            continue;
        }

        // 0x0FA0 = TextCharsAtom (UTF-16LE) - process immediately to set shape.text
        if (recType == ESCHER_TXBX_TEXT_DATA && recLen > 0) {
            // Decode UTF-16LE text
            std::string text;
            for (size_t i = 0; i + 1 < recLen; i += 2) {
                uint16_t ch = data[pos + 8 + i] | (data[pos + 8 + i + 1] << 8);
                if (ch == 0) continue;
                if (ch < 0x80) text += (char)ch;
                else if (ch < 0x800) {
                    text += (char)(0xC0 | (ch >> 6));
                    text += (char)(0x80 | (ch & 0x3F));
                } else {
                    text += (char)(0xE0 | (ch >> 12));
                    text += (char)(0x80 | ((ch >> 6) & 0x3F));
                    text += (char)(0x80 | (ch & 0x3F));
                }
            }

            if (!text.empty() && text.size() > 2) {
                shape.text = text;
                shape.isTextShape = true;
                OH_LOG_INFO(LOG_APP, "PPT: Found text in 0x0FA0: '%{public}s' len=%{public}u",
                            text.substr(0,30).c_str(), (uint32_t)text.size());
            }
        }
        // 0x0FA8 = TextBytesAtom (ASCII) - process immediately
        else if (recType == PPT_RT_TEXT_BYTES_ATOM && recLen > 0) {
            std::string text(reinterpret_cast<const char*>(data + pos + 8), recLen);
            while (!text.empty() && (text.back() == '\0' || text.back() == ' ' || text.back() == '\n'))
                text.pop_back();
            if (!text.empty()) {
                shape.text = text;
                shape.isTextShape = true;
                OH_LOG_INFO(LOG_APP, "PPT: Found text in 0x0FA8: '%{public}s' len=%{public}u",
                            text.substr(0,30).c_str(), (uint32_t)text.size());
            }
        }
        // 0x0FA1 = StyleTextPropAtom - store position for later parsing (after text is set)
        else if (recType == 0x0FA1 && recLen >= 4) {
            styleTextPropPos = pos + 8;  // Record content start
            styleTextPropLen = recLen;
        }

        pos += 8 + recLen;
    }

    // Second: parse StyleTextPropAtom now that shape.text is set
    if (styleTextPropPos > 0 && styleTextPropLen > 0 && !shape.text.empty()) {
        const uint8_t* d = data + styleTextPropPos;
        size_t dLen = styleTextPropLen;
        size_t textLen = shape.text.size();
            // PPT uses UTF-16 character count, not UTF-8 byte length
            // Calculate UTF-16 char count by counting code points
            size_t utf16Count = 0;
            for (size_t i = 0; i < textLen; ) {
                uint8_t c = shape.text[i];
                if (c < 0x80) { i += 1; utf16Count += 1; }
                else if (c < 0xC0) { i += 1; utf16Count += 1; }  // invalid, count as 1
                else if (c < 0xE0) { i += 2; utf16Count += 1; }  // 2-byte UTF-8 = 1 UTF-16
                else if (c < 0xF0) { i += 3; utf16Count += 1; }  // 3-byte UTF-8 = 1 UTF-16
                else { i += 4; utf16Count += 2; }                 // 4-byte UTF-8 = 2 UTF-16 (surrogate pair)
            }
            OH_LOG_INFO(LOG_APP, "PPT: StyleTextPropAtom: textLenUtf8=%{public}u utf16Count=%{public}u",
                        (uint32_t)textLen, (uint32_t)utf16Count);
            // Per MS-PPT spec: sum of PF count MUST equal number of characters in text
            // Python uses condition "total_pf_count < text_len" to stop loop
            uint32_t pfTarget = static_cast<uint32_t>(utf16Count);  // Stop when pfTotalCount >= utf16Count
            size_t off = 0;

            // ---- Phase 1: Parse and skip rgTextPFRun ----
            // PFMasks bits per MS-PPT spec 2.9.21:
            //   0=hasBullet, 1=bulletHasFont, 2=bulletHasColor, 3=bulletHasSize,
            //   4=bulletFont, 5=bulletColor, 6=bulletSize, 7=bulletChar,
            //   8=leftMargin, 9=unused, 10=indent, 11=align, 12=lineSpacing,
            //   13=spaceBefore, 14=spaceAfter, 15=defaultTabSize, 16=fontAlign,
            //   17=charWrap, 18=wordWrap, 19=overflow, 20=tabStops, 21=textDirection
            uint32_t pfTotalCount = 0;
            size_t pfRunIdx = 0;
            while (off + 6 <= dLen && pfTotalCount < pfTarget) {
                uint32_t count = d[off] | (d[off+1] << 8) | (d[off+2] << 16) | (d[off+3] << 24);
                OH_LOG_INFO(LOG_APP, "PPT: PF Run %{public}u: off=%{public}u count=%{public}u pfTarget=%{public}u",
                            pfRunIdx, (uint32_t)off, count, pfTarget);
                if (count == 0 || count > pfTarget + 2) {
                    OH_LOG_INFO(LOG_APP, "PPT: PF Run break: count=%{public}u invalid", count);
                    break;
                }
                off += 4;  // count
                off += 2;  // indentLevel
                if (off + 4 > dLen) break;
                uint32_t pfMasks = d[off] | (d[off+1] << 8) | (d[off+2] << 16) | (d[off+3] << 24);
                OH_LOG_INFO(LOG_APP, "PPT: PF masks=0x%{public}08X at off=%{public}u", pfMasks, (uint32_t)off);
                off += 4;  // masks
                if (pfMasks & 0x0F)    off += 2;   // bulletFlags (bits 0-3)
                if (pfMasks & 0x80)    off += 2;   // bulletChar (bit 7)
                if (pfMasks & 0x10)    off += 2;   // bulletFontRef (bit 4)
                if (pfMasks & 0x40)    off += 2;   // bulletSize (bit 6)
                if (pfMasks & 0x20)    off += 4;   // bulletColor (bit 5)
                if (pfMasks & 0x800)   off += 2;   // textAlignment (bit 11)
                if (pfMasks & 0x1000)  off += 2;   // lineSpacing (bit 12)
                if (pfMasks & 0x2000)  off += 2;   // spaceBefore (bit 13)
                if (pfMasks & 0x4000)  off += 2;   // spaceAfter (bit 14)
                if (pfMasks & 0x100)   off += 2;   // leftMargin (bit 8)
                if (pfMasks & 0x400)   off += 2;   // indent (bit 10)
                if (pfMasks & 0x8000)  off += 2;   // defaultTabSize (bit 15)
                if (pfMasks & 0x100000) {           // tabStops (bit 20)
                    if (off + 2 <= dLen) {
                        uint16_t tabCount = d[off] | (d[off+1] << 8);
                        off += 2 + tabCount * 4;
                    }
                }
                if (pfMasks & 0x10000) off += 2;   // fontAlign (bit 16)
                if (pfMasks & 0xE0000) off += 2;   // wrapFlags (bits 17-19)
                if (pfMasks & 0x200000) off += 2;  // textDirection (bit 21)
                pfTotalCount += count;
                pfRunIdx++;
                OH_LOG_INFO(LOG_APP, "PPT: PF Run %{public}u done: consumed %{public}u bytes, pfTotalCount=%{public}u",
                            pfRunIdx-1, (uint32_t)off, pfTotalCount);
            }

            // ---- Phase 2: Parse rgTextCFRun - extract formatting ----
            // CFMasks bits per MS-PPT spec 2.9.15:
            //   0=bold, 1=italic, 2=underline, 3=unused, 4=shadow, 5=fehint,
            //   6=unused, 7=kumi, 8=unused, 9=emboss, 10-13=fHasStyle(4bits),
            //   14-15=unused, 16=typeface, 17=size, 18=color, 19=position,
            //   20=pp10ext, 21=oldEATypeface, 22=ansiTypeface, 23=symbolTypeface
            bool fmtExtracted = false;
            uint32_t cfTotalCount = 0;

            // Debug: log before CF parsing
            OH_LOG_INFO(LOG_APP, "PPT: StyleTextPropAtom BEFORE CF: off=%{public}u dLen=%{public}u pfTotalCount=%{public}u textLen=%{public}u",
                        (uint32_t)off, (uint32_t)dLen, pfTotalCount, (uint32_t)textLen);

            while (off + 4 <= dLen && cfTotalCount < pfTotalCount) {
                uint32_t count = d[off] | (d[off+1] << 8) | (d[off+2] << 16) | (d[off+3] << 24);
                OH_LOG_INFO(LOG_APP, "PPT: CF Run start: off=%{public}u count=%{public}u cfTotalCount=%{public}u",
                            (uint32_t)off, count, cfTotalCount);
                if (count == 0 || count > pfTotalCount) break;
                off += 4;
                if (off + 4 > dLen) break;
                uint32_t cfMasks = d[off] | (d[off+1] << 8) | (d[off+2] << 16) | (d[off+3] << 24);
                off += 4;
                OH_LOG_INFO(LOG_APP, "PPT: CF masks=0x%{public}08X hasFontStyle=%{public}d", cfMasks, (int)((cfMasks & 0x3EB7) != 0));
                // fontStyle (2 bytes) - if any of bits 0,1,2,4,5,7,9,10-13
                bool hasFontStyle = (cfMasks & 0x3EB7) != 0;
                if (hasFontStyle && off + 2 <= dLen) {
                    if (!fmtExtracted) {
                        uint16_t fontStyle = d[off] | (d[off+1] << 8);
                        shape.textFmt.isBold = (fontStyle & 0x0001) != 0;
                    }
                    off += 2;
                }
                // fontRef (2 bytes) - bit 16
                if ((cfMasks & 0x10000) && off + 2 <= dLen) off += 2;
                // oldEAFontRef (2 bytes) - bit 21
                if ((cfMasks & 0x200000) && off + 2 <= dLen) off += 2;
                // ansiFontRef (2 bytes) - bit 22
                if ((cfMasks & 0x400000) && off + 2 <= dLen) off += 2;
                // symbolFontRef (2 bytes) - bit 23
                if ((cfMasks & 0x800000) && off + 2 <= dLen) off += 2;
                // fontSize (2 bytes) - bit 17, in points
                if ((cfMasks & 0x20000) && off + 2 <= dLen) {
                    if (!fmtExtracted) {
                        int16_t fontSizePt = (int16_t)(d[off] | (d[off+1] << 8));
                        if (fontSizePt > 0 && fontSizePt <= 4000) {
                            shape.textFmt.fontSize = fontSizePt * 100;
                            shape.textFmt.hasExplicitSize = true;
                        }
                    }
                    off += 2;
                }
                // color (4 bytes) - bit 18, ColorIndexStruct
                if ((cfMasks & 0x40000) && off + 4 <= dLen) {
                    if (!fmtExtracted) {
                        uint8_t red = d[off], green = d[off+1], blue = d[off+2];
                        uint8_t colorIndex = d[off+3];
                        if (colorIndex == 0xFE) {
                            shape.textFmt.hasTextColor = true;
                            shape.textFmt.textColor = (red << 16) | (green << 8) | blue;
                        }
                    }
                    off += 4;
                }
                // position (2 bytes) - bit 19
                if ((cfMasks & 0x80000) && off + 2 <= dLen) off += 2;
                if (!fmtExtracted && count > 1) fmtExtracted = true;
                cfTotalCount += count;
            }

            OH_LOG_INFO(LOG_APP, "PPT: StyleTextPropAtom: bold=%{public}d sz=%{public}dpt color=0x%{public}06X "
                        "pfCount=%{public}u cfCount=%{public}u consumed=%{public}u/%{public}u",
                        (int)shape.textFmt.isBold, shape.textFmt.hasExplicitSize ? shape.textFmt.fontSize/100 : 0,
                        shape.textFmt.textColor, pfTotalCount, cfTotalCount, (uint32_t)off, (uint32_t)dLen);
    }
}

// Recursively scan for text atoms within containers (depth-first)
// data: pointer to the container content (starting at container data, offsets are relative)
// containerLen: length of the container content
// ============================================================================
// Enhanced Shape Scanning for complete PPTX generation
// ============================================================================

// Scan a Shape Container (0xF004/61444) to extract complete shape data
// including position (ChildAnchor), style (FOPT), and text
static void scanShapeContainerEnhanced(const uint8_t* data, size_t containerLen,
                                        ShapeData& shape, int depth = 0) {
    if (depth > 10) return;

    size_t pos = 0;
    while (pos + 8 <= containerLen) {
        uint8_t firstByte = data[pos];
        uint8_t recVer = firstByte & 0x0F;
        uint16_t recInstance = ((firstByte >> 4) & 0x0F) | (data[pos + 1] << 4);
        uint16_t recType = data[pos + 2] | (data[pos + 3] << 8);
        uint32_t recLen = data[pos + 4] | (data[pos + 5] << 8) |
                         (data[pos + 6] << 16) | (data[pos + 7] << 24);

        // Safety check
        if (recLen > containerLen - pos - 8 || recLen > 1048576) {
            pos += 8;
            continue;
        }

        size_t endPos = pos + 8 + recLen;

        // Handle specific record types
        if (recType == ESCHER_CHILD_ANCHOR) {  // 0xF010 - OfficeArtClientAnchor (position per MS-PPT 2.7.1)
            parseChildAnchor(data + pos + 8, recLen, shape.transform, recType);

        } else if (recType == ESCHER_FOPT) {  // 0xF00B - Properties
            if (recLen > 0 && recInstance > 0) {
                parseEscherFOPTEnhanced(data + pos + 8, recLen, recInstance, shape);
            }

        } else if (recType == PPT_RT_TEXT_CHARS_ATOM || recType == PPT_RT_TEXT_BYTES_ATOM) {
            // Direct text atom in shape
            if (recLen > 0) {
                std::string text = extractPPTText(data + pos + 8, recType, recLen);
                if (!text.empty()) {
                    shape.text = text;
                    shape.isTextShape = true;
                }
            }

        } else if (recType == ESCHER_CLIENT_TEXTBOX) {  // 0xF00D - OfficeArtClientTextbox container
            // Per MS-PPT spec: Contains text records like 0x0FA0 (TextCharsAtom equivalent)
            // This means the shape has a textbox - mark it and scan for actual display text
            shape.hasTextbox = true;
            if (recLen > 8) {
                scanClientTextboxContent(data + pos + 8, recLen, shape);
            }

        } else if (recType == ESCHER_F122_OLEPACKAGE) {  // 0xF122 - Embedded OLE package
            // Per MS-ODRAW spec: OLE packages can contain either images or shape XML
            // inst=1: contains image (drs/media/image1.png)
            // inst=2: contains shape XML with text (drs/shapexml.xml)
            if (recLen > 20) {
                uint8_t oleInst = ((data[pos] >> 4) & 0x0F) | (data[pos + 1] << 4);
                OH_LOG_INFO(LOG_APP, "PPT: Found F122 OLE package at pos %{public}d, len=%{public}d, inst=%{public}d",
                            (int)pos, (int)recLen, (int)oleInst);

                if (oleInst == 2) {
                    // inst=2: Shape with text in shapexml.xml
                    std::string xmlText = extractF122ShapeXmlText(data + pos + 8, recLen);
                    if (!xmlText.empty()) {
                        shape.text = xmlText;
                        shape.isTextShape = true;
                        OH_LOG_INFO(LOG_APP, "PPT: Extracted text from F122 shapexml: '%{public}s'",
                                    xmlText.substr(0, 60).c_str());
                    }
                    // Also try to extract image (icon/bullet)
                    if (extractF122EmbeddedImage(data + pos + 8, recLen, shape.imageRef.embeddedData)) {
                        shape.imageRef.hasImage = true;
                        shape.imageRef.isEmbedded = true;
                    }
                } else {
                    // inst=1 or other: extract image only
                    if (extractF122EmbeddedImage(data + pos + 8, recLen, shape.imageRef.embeddedData)) {
                        shape.imageRef.hasImage = true;
                        shape.imageRef.isEmbedded = true;
                        shape.isPictureShape = true;
                        OH_LOG_INFO(LOG_APP, "PPT: Extracted embedded image from F122, size=%{public}d",
                                    (int)shape.imageRef.embeddedData.size());
                    }
                }
            }

        } else if (isPPTContainer(recType, recVer) && recLen > 8) {
            // Nested container (GroupShape, etc.) - recurse
            scanShapeContainerEnhanced(data + pos + 8, recLen, shape, depth + 1);
        }

        pos = endPos;
    }
}

// Scan Slide Container for all shapes (enhanced version)
// Returns PPTSlideDataEnhanced with complete shape information
static void scanSlideForShapes(const uint8_t* data, size_t containerLen,
                                PPTSlideDataEnhanced& slide) {
    size_t pos = 0;
    int shapeIdCounter = 2;  // Shape IDs start at 2 (1 is reserved)

    while (pos + 8 <= containerLen) {
        uint8_t firstByte = data[pos];
        uint8_t recVer = firstByte & 0x0F;
        uint16_t recType = data[pos + 2] | (data[pos + 3] << 8);
        uint32_t recLen = data[pos + 4] | (data[pos + 5] << 8) |
                         (data[pos + 6] << 16) | (data[pos + 7] << 24);

        if (recLen > containerLen - pos - 8 || recLen > 1048576) {
            pos += 8;
            continue;
        }

        // Look for Shape Container (61444 = 0xF004) only
        // Note: SpgrContainer (61443 = 0xF003) is a GROUP container - recurse into it, NOT treat as single shape!
        if (recType == 61444) {  // Only SpContainer
            ShapeData shape;
            shape.shapeId = shapeIdCounter++;

            // Scan the shape container content
            scanShapeContainerEnhanced(data + pos + 8, recLen, shape, 0);

            // Filter: include shapes with meaningful content
            // - Shapes with actual display text (from 0xF00D/0x0FA0, NOT wzName)
            // - Shapes with images
            // - Connector shapes
            // - Background/decorative shapes with fill colors and valid positions
            // IMPORTANT: Must have a valid shape name to exclude phantom/placeholder shapes
            bool hasContent = shape.isTextShape || shape.imageRef.hasImage || shape.isConnector;

            // Background/decorative shapes: require name + fill + valid position
            // Shapes without name are likely phantom placeholders that shouldn't render
            if (!hasContent && !shape.shapeName.empty() &&
                shape.style.hasFill && shape.transform.cx > 0 && shape.transform.cy > 0) {
                // Only include if fill color is not "no fill" (0xFFFFFFFF)
                if (shape.style.fillColor != 0xFFFFFFFF) {
                    hasContent = true;
                }
            }
            // Shapes with textbox and name: often background containers
            if (!hasContent && !shape.shapeName.empty() &&
                shape.hasTextbox && shape.transform.cx > 0 && shape.transform.cy > 0) {
                hasContent = true;
            }
            if (hasContent) {
                slide.shapes.push_back(shape);
                OH_LOG_INFO(LOG_APP, "PPT: Found shape id=%{public}d, name='%{public}s', text='%{public}s', img=%{public}d, connector=%{public}d, pos=(%{public}d,%{public}d)",
                            shape.shapeId, shape.shapeName.substr(0,20).c_str(),
                            shape.text.substr(0,30).c_str(), (int)shape.imageRef.hasImage,
                            (int)shape.isConnector, (int)shape.transform.x, (int)shape.transform.y);
            }

        } else if (isPPTContainer(recType, recVer) && recLen > 8) {
            // Other containers (PPDrawing, etc.) - recurse to find shapes
            scanSlideForShapes(data + pos + 8, recLen, slide);
        }

        pos += 8 + recLen;
    }
}

// ============================================================================
// Legacy text scanning (backward compatibility)
// ============================================================================

static void scanForTextAtoms(const uint8_t* data, size_t startOffset, size_t containerLen,
                             PPTSlideData& slide, int depth = 0) {
    if (depth > 15) return;  // Prevent infinite recursion (increased limit for nested Escher)

    // Check if there's enough space for at least one record header (8 bytes)
    if (startOffset + 8 > containerLen) {
        return;
    }

    size_t pos = startOffset;
    while (pos + 8 <= containerLen) {
        // Read record header per MS-PPT spec:
        // Byte 0: recVer (4 bits low) | recInstance low (4 bits high)
        // Byte 1: recInstance high (8 bits)
        // Bytes 2-3: recType (16 bits LE)
        // Bytes 4-7: recLen (32 bits LE)
        uint8_t firstByte = data[pos];
        uint8_t recVer = firstByte & 0x0F;  // Low 4 bits of byte 0
        uint16_t recInstance = ((firstByte >> 4) & 0x0F) | (data[pos + 1] << 4);  // 12 bits
        uint16_t recType = data[pos + 2] | (data[pos + 3] << 8);
        uint32_t recLen = data[pos + 4] | (data[pos + 5] << 8) |
                         (data[pos + 6] << 16) | (data[pos + 7] << 24);

        // Safety check: recLen should not exceed remaining container space
        // and should not be unreasonably large (> 1MB for slide content)
        size_t remainingSpace = containerLen - pos;
        if (recLen > remainingSpace - 8 || recLen > 1048576) {
            // Invalid record length - skip this position and try next
            OH_LOG_WARN(LOG_APP, "PPT: Invalid recLen %{public}d at pos %{public}d, remaining %{public}d, type %{public}d, ver=%{public}d",
                        (int)recLen, (int)pos, (int)remainingSpace, (int)recType, (int)recVer);
            pos += 8;  // Skip just the header
            continue;
        }

        // Calculate end position
        size_t endPos = pos + 8 + recLen;

        if (recType == PPT_RT_TEXT_CHARS_ATOM || recType == PPT_RT_TEXT_BYTES_ATOM) {
            // Found text - extract it (data + pos + 8 points to text content)
            if (recLen > 0) {
                std::string text = extractPPTText(data + pos + 8, recType, recLen);
                if (!text.empty()) {
                    slide.textContent.push_back(text);
                    OH_LOG_INFO(LOG_APP, "PPT: Found text (depth %{public}d, type %{public}d, len %{public}d): '%{public}s'",
                                depth, (int)recType, (int)recLen, text.c_str());
                }
            }
        } else if (recType == ESCHER_FOPT) {
            // OfficeArtFOPT (0xF00B) - Escher property table with text in complex properties
            // recInstance = property count, recVer should be 0x3 per MS-ODRAW
            if (recLen > 0 && recInstance > 0) {
                OH_LOG_INFO(LOG_APP, "PPT: Found FOPT at %{public}d, props=%{public}d, len=%{public}d, depth=%{public}d",
                            (int)pos, (int)recInstance, (int)recLen, depth);
                auto escherTexts = parseEscherFOPT(data + pos + 8, recLen, recInstance);
                for (auto& text : escherTexts) {
                    slide.textContent.push_back(text);
                }
            }
        } else if (isPPTContainer(recType, recVer)) {
            // Container - recurse if there's at least room for one child record header
            // Minimum: 8 bytes for one child header + potentially more content
            // Changed from recLen > 16 to recLen > 8 to catch smaller containers with text
            if (recLen > 8 && endPos > pos + 8) {
                OH_LOG_INFO(LOG_APP, "PPT: Entering container %{public}d (0x%{public}04X) at %{public}d, len=%{public}d, depth=%{public}d",
                            (int)recType, recType, (int)pos, (int)recLen, depth);
                // Pass pointer to container content (data + pos + 8) and its length (recLen)
                scanForTextAtoms(data + pos + 8, 0, recLen, slide, depth + 1);
            } else if (recLen > 0 && recLen <= 8) {
                // Small container - might still have content, log it
                OH_LOG_INFO(LOG_APP, "PPT: Small container %{public}d (0x%{public}04X) at %{public}d, len=%{public}d, skipped",
                            (int)recType, recType, (int)pos, (int)recLen);
            }
        }

        pos = endPos;
    }
}

// Parse Slide Container to extract text (using recursive scanner)
static void parseSlideContainer(const uint8_t* data, size_t offset, size_t maxLen,
                                 PPTSlideData& slide) {
    // Slide Container contains: SlideAtom + ShapeContainer (with text)
    // We use recursive scanner to find all TextCharsAtom/TextBytesAtom atoms

    if (offset + 8 > maxLen) return;

    // PPT Container record format (MS-PPT):
    // offset+0-1: recVer (4 bits) + recInstance (12 bits)
    // offset+2-3: recType
    // offset+4-7: recLen (4 bytes)
    uint32_t containerLen = data[offset + 4] | (data[offset + 5] << 8) |
                            (data[offset + 6] << 16) | (data[offset + 7] << 24);

    OH_LOG_INFO(LOG_APP, "PPT: Slide container at %{public}d, len=%{public}d",
                (int)offset, (int)containerLen);

    size_t endPos = offset + 8 + containerLen;
    if (endPos > maxLen) endPos = maxLen;

    // Recursively scan for text atoms starting from inside the Slide Container
    scanForTextAtoms(data, offset + 8, endPos, slide, 0);

    OH_LOG_INFO(LOG_APP, "PPT: Slide parsed, found %{public}d text items",
                (int)slide.textContent.size());
}

// Parse Document Container to find slide offsets
static std::vector<size_t> parseDocumentContainer(const uint8_t* data, size_t offset, size_t maxLen) {
    std::vector<size_t> slideOffsets;

    // Document Container contains: DocumentAtom + SlideListWithText + Master/Note containers
    // SlideListWithText has SlidePersistAtom entries with slide offsets

    size_t pos = offset + 8;  // Skip container header
    // PPT Container record format (MS-PPT):
    // offset+0-1: recVer (4 bits) + recInstance (12 bits)
    // offset+2-3: recType
    // offset+4-7: recLen (4 bytes)
    uint32_t containerLen = data[offset + 4] | (data[offset + 5] << 8) |
                            (data[offset + 6] << 16) | (data[offset + 7] << 24);

    OH_LOG_INFO(LOG_APP, "PPT: Document container at %{public}d, len=%{public}d",
                (int)offset, (int)containerLen);

    size_t endPos = offset + 8 + containerLen;
    if (endPos > maxLen) endPos = maxLen;

    while (pos + 8 <= endPos) {
        uint16_t recType;
        uint32_t recLen;
        if (!readPPTRecordHeader(data, pos, maxLen, recType, recLen)) break;

        OH_LOG_INFO(LOG_APP, "PPT: Doc record at %{public}d: type=%{public}d(0x%{public}04X), len=%{public}d",
                    (int)pos, (int)recType, recType, (int)recLen);

        // Per MS-PPT spec section 2.4.2: DocumentAtom contains slideSize in master units
        // DocumentAtom: rh(8) + slideSize(8: PointStruct x,y) + notesSize(8) + serverZoom(8) + ...
        // slideSize.x = width in master units, slideSize.y = height in master units
        if (recType == PPT_RT_DOCUMENT_ATOM && recLen >= 16) {
            int32_t slideW = data[pos + 8] | (data[pos + 9] << 8) |
                             (data[pos + 10] << 16) | (data[pos + 11] << 24);
            int32_t slideH = data[pos + 12] | (data[pos + 13] << 8) |
                             (data[pos + 14] << 16) | (data[pos + 15] << 24);
            // Convert master units to EMU using exact formula: EMU = masterUnits * 914400 / 576
            g_slideWidthEmu = (int32_t)((int64_t)slideW * 914400 / 576);
            g_slideHeightEmu = (int32_t)((int64_t)slideH * 914400 / 576);
            OH_LOG_INFO(LOG_APP, "PPT: DocumentAtom slideSize: %{public}d x %{public}d master units = %{public}d x %{public}d EMU",
                        (int)slideW, (int)slideH, (int)g_slideWidthEmu, (int)g_slideHeightEmu);
        }

        if (recType == PPT_RT_SLIDE_LIST_WITH_TEXT) {
            // SlideListWithText contains SlidePersistAtom entries
            // Each SlidePersistAtom: slideId(4) + persistIdRef(4) + ...
            // persistIdRef references the slide container offset

            OH_LOG_INFO(LOG_APP, "PPT: Found SlideListWithText at %{public}d", (int)pos);

            size_t innerPos = pos + 8;
            size_t innerEnd = pos + 8 + recLen;
            int slideCount = 0;

            while (innerPos + 8 <= innerEnd) {
                uint16_t innerType;
                uint32_t innerLen;
                if (!readPPTRecordHeader(data, innerPos, maxLen, innerType, innerLen)) break;

                if (innerType == PPT_RT_SLIDE_PERSIST_ATOM) {
                    // SlidePersistAtom structure:
                    // Offset 0-7: header
                    // Offset 8-11: slideId (4 bytes)
                    // Offset 12-15: persistIdRef (4 bytes) - slide offset reference
                    // ... more fields

                    if (innerLen >= 20) {
                        uint32_t persistIdRef = data[innerPos + 12] | (data[innerPos + 13] << 8) |
                                               (data[innerPos + 14] << 16) | (data[innerPos + 15] << 24);

                        // For many PPT files, persistIdRef is the actual offset
                        // In full implementation, need to resolve via PersistPtrIncrementalBlock
                        slideOffsets.push_back(persistIdRef);
                        slideCount++;
                        OH_LOG_INFO(LOG_APP, "PPT: Slide %{public}d persistIdRef=%{public}d",
                                    slideCount, (int)persistIdRef);
                    }
                }

                innerPos += 8 + innerLen;
            }

            OH_LOG_INFO(LOG_APP, "PPT: SlideListWithText has %{public}d slides", slideCount);
        }

        pos += 8 + recLen;
    }

    return slideOffsets;
}

bool OfficeConverter::convertPPT(const std::string& inputPath, const std::string& outputPath,
                                  ConversionResult& result) {
    OH_LOG_INFO(LOG_APP, "OfficeConverter: convertPPT start, input=%{public}s", inputPath.c_str());

    // Remove file:// prefix and ensure absolute path
    std::string filePath = inputPath;
    if (filePath.find("file://") == 0) {
        filePath = filePath.substr(7);
    }
    if (filePath.length() > 0 && filePath[0] != '/') {
        filePath = "/" + filePath;
    }

    // Read file
    FILE* file = fopen(filePath.c_str(), "rb");
    if (!file) {
        result.errorMsg = "Cannot open file: " + filePath;
        return false;
    }

    fseek(file, 0, SEEK_END);
    size_t fileSize = ftell(file);
    fseek(file, 0, SEEK_SET);

    std::vector<uint8_t> fileData(fileSize);
    fread(fileData.data(), 1, fileSize, file);
    fclose(file);

    // Parse OLE2 structure
    std::vector<OLE2Entry> entries;
    if (!parseOLE2Header(fileData.data(), fileSize, entries)) {
        result.errorMsg = "Failed to parse OLE2 header";
        return false;
    }

    // Find PowerPoint Document stream - use largest stream (excluding Pictures)
    const OLE2Entry* pptDocEntry = nullptr;

    OH_LOG_INFO(LOG_APP, "PPT: Total OLE2 entries: %{public}d", (int)entries.size());
    for (const auto& entry : entries) {
        OH_LOG_INFO(LOG_APP, "PPT: OLE2 entry '%{public}s', stream=%{public}d, size=%{public}d",
                    entry.name.c_str(), (int)entry.isStream, (int)entry.size);

        if (entry.isStream && entry.size > 0) {
            if (entry.name.find("Pictures") == std::string::npos &&
                entry.name.find("Current") == std::string::npos &&
                entry.name.find("Summary") == std::string::npos &&
                entry.name.find("Document") != std::string::npos) {
                pptDocEntry = &entry;
            }
        }
    }

    // If no explicit Document stream, find largest stream
    if (!pptDocEntry) {
        for (const auto& entry : entries) {
            if (entry.isStream && entry.size > 0) {
                if (entry.name.find("Pictures") == std::string::npos &&
                    entry.name.find("Current") == std::string::npos &&
                    entry.name.find("Summary") == std::string::npos) {
                    if (!pptDocEntry || entry.size > pptDocEntry->size) {
                        pptDocEntry = &entry;
                    }
                }
            }
        }
    }

    // Read PowerPoint Document stream
    std::vector<uint8_t> pptDocData;
    if (pptDocEntry) {
        if (!readOLE2Stream(fileData.data(), fileSize, *pptDocEntry, pptDocData)) {
            result.errorMsg = "Failed to read PowerPoint Document stream";
            return false;
        }
    } else {
        // Fallback: Scan entire file for PPT records
        size_t docOffset = 0;
        for (size_t pos = 512; pos + 8 < fileSize; pos++) {
            uint16_t recType = fileData[pos + 2] | (fileData[pos + 3] << 8);
            if (recType == PPT_RT_DOCUMENT) {
                docOffset = pos;
                break;
            }
        }

        if (docOffset > 0) {
            pptDocData.assign(fileData.begin() + docOffset, fileData.end());
        } else {
            pptDocData.assign(fileData.begin() + 512, fileData.end());
        }
    }

    // Read Pictures stream and extract images
    std::vector<BlipImage> images;
    const OLE2Entry* picturesEntry = nullptr;
    for (const auto& entry : entries) {
        if (entry.name == "Pictures") {
            picturesEntry = &entry;
            break;
        }
    }

    if (picturesEntry) {
        std::vector<uint8_t> picturesData;
        if (readOLE2Stream(fileData.data(), fileSize, *picturesEntry, picturesData)) {
            images = parsePicturesStream(picturesData.data(), picturesData.size());
        }
    }

    // ENHANCED: Build PersistId to BLIP index mapping
    // In PPT, pib property (0x0004) references a PersistId that maps to a BLIP in Pictures stream
    std::map<uint32_t, uint16_t> persistIdToBlipIndex;
    for (size_t i = 0; i < images.size(); i++) {
        // Simple mapping: index i corresponds to PersistId i+1 (common case)
        persistIdToBlipIndex[i + 1] = (uint16_t)i;
        OH_LOG_INFO(LOG_APP, "PPT: Mapped PersistId %{public}d -> BLIP %{public}d", (int)(i + 1), (int)i);
    }

    // ENHANCED: Use enhanced shape scanning for complete PPTX generation
    std::vector<PPTSlideDataEnhanced> slidesEnhanced;

    // First pass: Find DocumentAtom to read slide size (per MS-PPT spec section 2.4.2)
    // DocumentAtom: slideSize.x/y in master units, recType=1001 (RT_DocumentAtom)
    for (size_t dp = 0; dp + 48 < pptDocData.size(); dp += 8) {
        uint16_t dType = pptDocData[dp + 2] | (pptDocData[dp + 3] << 8);
        if (dType == PPT_RT_DOCUMENT_ATOM) {
            uint32_t dLen = pptDocData[dp + 4] | (pptDocData[dp + 5] << 8) |
                           (pptDocData[dp + 6] << 16) | (pptDocData[dp + 7] << 24);
            if (dLen >= 16 && dp + 8 + dLen <= pptDocData.size()) {
                int32_t sW = pptDocData[dp + 8] | (pptDocData[dp + 9] << 8) |
                             (pptDocData[dp + 10] << 16) | (pptDocData[dp + 11] << 24);
                int32_t sH = pptDocData[dp + 12] | (pptDocData[dp + 13] << 8) |
                             (pptDocData[dp + 14] << 16) | (pptDocData[dp + 15] << 24);
                g_slideWidthEmu = (int32_t)((int64_t)sW * 914400 / 576);
                g_slideHeightEmu = (int32_t)((int64_t)sH * 914400 / 576);
                OH_LOG_INFO(LOG_APP, "PPT: DocumentAtom slideSize: %{public}d x %{public}d master = %{public}d x %{public}d EMU",
                            (int)sW, (int)sH, (int)g_slideWidthEmu, (int)g_slideHeightEmu);
            }
            break;
        }
    }

    OH_LOG_INFO(LOG_APP, "PPT: Scanning for Slide Containers with enhanced parsing");

    size_t pos = 0;
    while (pos + 8 < pptDocData.size()) {
        uint16_t recType = pptDocData[pos + 2] | (pptDocData[pos + 3] << 8);
        uint32_t recLen = pptDocData[pos + 4] | (pptDocData[pos + 5] << 8) |
                         (pptDocData[pos + 6] << 16) | (pptDocData[pos + 7] << 24);

        if (recType == PPT_RT_SLIDE) {  // 1006 = 0x03EE
            OH_LOG_INFO(LOG_APP, "PPT: Found Slide Container at %{public}d, len=%{public}d", (int)pos, (int)recLen);

            PPTSlideDataEnhanced slide;
            slide.slideIndex = slidesEnhanced.size() + 1;

            size_t containerStart = pos + 8;
            size_t containerLen = recLen;
            if (containerStart + containerLen > pptDocData.size()) {
                containerLen = pptDocData.size() - containerStart;
            }

            // Use enhanced shape scanner
            scanSlideForShapes(pptDocData.data() + containerStart, containerLen, slide);

            // Resolve image references (PersistId -> BLIP index)
            for (auto& shape : slide.shapes) {
                if (shape.imageRef.hasImage && shape.imageRef.persistId > 0) {
                    auto it = persistIdToBlipIndex.find(shape.imageRef.persistId);
                    if (it != persistIdToBlipIndex.end()) {
                        shape.imageRef.blipIndex = it->second;
                        OH_LOG_INFO(LOG_APP, "PPT: Shape %{public}d resolved PersistId %{public}d -> image %{public}d",
                                    shape.shapeId, (int)shape.imageRef.persistId, (int)shape.imageRef.blipIndex);
                    }
                }
            }

            // Log text formatting parsed from PPT binary (TextMasterStyleAtom)
            for (auto& shape : slide.shapes) {
                if (!shape.isTextShape || shape.text.empty()) continue;
                OH_LOG_INFO(LOG_APP, "PPT: Slide %{public}d shape '%{public}s' fmt: sz=%{public}dpt bold=%{public}d color=0x%{public}06X explicitSz=%{public}d hasColor=%{public}d",
                    (int)(slidesEnhanced.size() + 1), shape.shapeName.substr(0,20).c_str(),
                    shape.textFmt.fontSize/100, (int)shape.textFmt.isBold,
                    shape.textFmt.textColor, (int)shape.textFmt.hasExplicitSize, (int)shape.textFmt.hasTextColor);
                if (!shape.textFmt.hasExplicitSize) {
                    OH_LOG_WARN(LOG_APP, "PPT: WARNING - no font size parsed for shape '%{public}s'", shape.shapeName.substr(0,20).c_str());
                }
                if (!shape.textFmt.hasTextColor) {
                    OH_LOG_WARN(LOG_APP, "PPT: WARNING - no text color parsed for shape '%{public}s'", shape.shapeName.substr(0,20).c_str());
                }
            }

            slidesEnhanced.push_back(slide);
            OH_LOG_INFO(LOG_APP, "PPT: Slide %{public}d parsed, %{public}d shapes (text:%{public}d, pic:%{public}d)",
                        (int)slidesEnhanced.size(), (int)slide.shapes.size(),
                        (int)slide.getTextShapes().size(), (int)slide.getPictureShapes().size());
        }

        if (recLen > 100000000 || (recType < 1000 && recType > 0xF000)) {
            pos += 8;
        } else {
            pos += 8 + recLen;
        }
    }

    OH_LOG_INFO(LOG_APP, "PPT: Total slides found: %{public}d, total images: %{public}d",
                (int)slidesEnhanced.size(), (int)images.size());

    // Generate PPTX (OOXML)
    if (slidesEnhanced.empty()) {
        result.errorMsg = "No slides found in presentation";
        return false;
    }

    // Create PPTX structure
    std::vector<std::pair<std::string, std::vector<uint8_t>>> pptxFiles;

    // [Content_Types].xml
    std::string contentTypes =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n"
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n"
        "<Default Extension=\"xml\" ContentType=\"application/xml\"/>\n";

    // Add image extensions if we have images
    if (!images.empty()) {
        contentTypes += "<Default Extension=\"png\" ContentType=\"image/png\"/>\n";
        contentTypes += "<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>\n";
        contentTypes += "<Default Extension=\"emf\" ContentType=\"image/x-emf\"/>\n";
        contentTypes += "<Default Extension=\"wmf\" ContentType=\"image/x-wmf\"/>\n";
    }

    contentTypes += "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>\n";
    contentTypes += "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>\n";
    contentTypes += "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>\n";
    contentTypes += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>\n";

    for (size_t i = 0; i < slidesEnhanced.size(); i++) {
        contentTypes += "<Override PartName=\"/ppt/slides/slide" + std::to_string(i + 1) + ".xml\" "
                       "ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>\n";
    }

    contentTypes += "</Types>";
    pptxFiles.push_back({"[Content_Types].xml", std::vector<uint8_t>(contentTypes.begin(), contentTypes.end())});

    // _rels/.rels
    std::string rels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"ppt/presentation.xml\"/>\n"
        "</Relationships>";
    pptxFiles.push_back({"_rels/.rels", std::vector<uint8_t>(rels.begin(), rels.end())});

    // ppt/theme/theme1.xml - minimal theme
    std::string themeXml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Office Theme\">\n"
        "<a:themeElements>\n"
        "<a:clrScheme name=\"Office\">\n"
        "<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1>\n"
        "<a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>\n"
        "<a:dk2><a:srgbClr val=\"44546A\"/></a:dk2>\n"
        "<a:lt2><a:srgbClr val=\"E7E6E6\"/></a:lt2>\n"
        "<a:accent1><a:srgbClr val=\"4472C4\"/></a:accent1>\n"
        "<a:accent2><a:srgbClr val=\"ED7D31\"/></a:accent2>\n"
        "<a:accent3><a:srgbClr val=\"A5A5A5\"/></a:accent3>\n"
        "<a:accent4><a:srgbClr val=\"FFC000\"/></a:accent4>\n"
        "<a:accent5><a:srgbClr val=\"5B9BD5\"/></a:accent5>\n"
        "<a:accent6><a:srgbClr val=\"70AD47\"/></a:accent6>\n"
        "<a:hlink><a:srgbClr val=\"0563C1\"/></a:hlink>\n"
        "<a:folHlink><a:srgbClr val=\"954F72\"/></a:folHlink>\n"
        "</a:clrScheme>\n"
        "<a:fontScheme name=\"Office\">\n"
        "<a:majorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>\n"
        "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont>\n"
        "</a:fontScheme>\n"
        "<a:fmtScheme name=\"Office\">\n"
        "<a:fillStyleLst>\n"
        "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>\n"
        "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>\n"
        "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>\n"
        "</a:fillStyleLst>\n"
        "<a:lnStyleLst>\n"
        "<a:ln w=\"6350\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/></a:ln>\n"
        "<a:ln w=\"12700\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/></a:ln>\n"
        "<a:ln w=\"19050\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/></a:ln>\n"
        "</a:lnStyleLst>\n"
        "<a:effectStyleLst>\n"
        "<a:effectStyle><a:effectLst/></a:effectStyle>\n"
        "<a:effectStyle><a:effectLst/></a:effectStyle>\n"
        "<a:effectStyle><a:effectLst/></a:effectStyle>\n"
        "</a:effectStyleLst>\n"
        "<a:bgFillStyleLst>\n"
        "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>\n"
        "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>\n"
        "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>\n"
        "</a:bgFillStyleLst>\n"
        "</a:fmtScheme>\n"
        "</a:themeElements>\n"
        "<a:objectDefaults/>\n"
        "<a:extraClrSchemeLst/>\n"
        "</a:theme>";
    pptxFiles.push_back({"ppt/theme/theme1.xml", std::vector<uint8_t>(themeXml.begin(), themeXml.end())});

    // ppt/slideMasters/_rels/slideMaster1.xml.rels
    std::string smRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>\n"
        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"../theme/theme1.xml\"/>\n"
        "</Relationships>";
    pptxFiles.push_back({"ppt/slideMasters/_rels/slideMaster1.xml.rels", std::vector<uint8_t>(smRels.begin(), smRels.end())});

    // ppt/slideMasters/slideMaster1.xml
    std::string slideMasterXml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<p:sldMaster xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">\n"
        "<p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree>"
        "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        "</p:spTree></p:cSld>\n"
        "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" "
        "accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>\n"
        "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst>\n"
        "</p:sldMaster>";
    pptxFiles.push_back({"ppt/slideMasters/slideMaster1.xml", std::vector<uint8_t>(slideMasterXml.begin(), slideMasterXml.end())});

    // ppt/slideLayouts/_rels/slideLayout1.xml.rels
    std::string slRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/>\n"
        "</Relationships>";
    pptxFiles.push_back({"ppt/slideLayouts/_rels/slideLayout1.xml.rels", std::vector<uint8_t>(slRels.begin(), slRels.end())});

    // ppt/slideLayouts/slideLayout1.xml
    std::string slideLayoutXml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<p:sldLayout xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" type=\"blank\" preserve=\"1\">\n"
        "<p:cSld name=\"Blank\"><p:spTree>"
        "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        "</p:spTree></p:cSld>\n"
        "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\n"
        "</p:sldLayout>";
    pptxFiles.push_back({"ppt/slideLayouts/slideLayout1.xml", std::vector<uint8_t>(slideLayoutXml.begin(), slideLayoutXml.end())});

    // ppt/presentation.xml
    std::string presentation =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<p:presentation xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" saveSubsetFonts=\"1\">\n"
        "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rIdSm\"/></p:sldMasterIdLst>\n"
        "<p:sldIdLst>\n";

    for (size_t i = 0; i < slidesEnhanced.size(); i++) {
        presentation += "<p:sldId id=\"" + std::to_string(256 + i) + "\" r:id=\"rId" + std::to_string(i + 1) + "\"/>\n";
    }

    presentation += "</p:sldIdLst>\n"
                    "<p:sldSz cx=\"" + std::to_string(g_slideWidthEmu) +
                    "\" cy=\"" + std::to_string(g_slideHeightEmu) + "\"/>\n"
                    "<p:notesSz cx=\"6858000\" cy=\"9144000\"/>\n"
                    "</p:presentation>";
    pptxFiles.push_back({"ppt/presentation.xml", std::vector<uint8_t>(presentation.begin(), presentation.end())});

    // ppt/_rels/presentation.xml.rels
    std::string presRels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
        "<Relationship Id=\"rIdSm\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>\n";

    for (size_t i = 0; i < slidesEnhanced.size(); i++) {
        presRels += "<Relationship Id=\"rId" + std::to_string(i + 1) + "\" "
                    "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" "
                    "Target=\"slides/slide" + std::to_string(i + 1) + ".xml\"/>\n";
    }

    presRels += "</Relationships>";
    pptxFiles.push_back({"ppt/_rels/presentation.xml.rels", std::vector<uint8_t>(presRels.begin(), presRels.end())});

    // Helper: XML escape text
    auto xmlEscape = [](std::string text) -> std::string {
        size_t pos;
        while ((pos = text.find('&')) != std::string::npos) text.replace(pos, 1, "&amp;");
        while ((pos = text.find('<')) != std::string::npos) text.replace(pos, 1, "&lt;");
        while ((pos = text.find('>')) != std::string::npos) text.replace(pos, 1, "&gt;");
        while ((pos = text.find('"')) != std::string::npos) text.replace(pos, 1, "&quot;");
        return text;
    };

    // Generate each slide XML with proper shapes and relationships
    // Track embedded images separately (from F122 OLE packages)
    std::vector<std::vector<uint8_t>> embeddedImages;  // Embedded images from F122

    for (size_t i = 0; i < slidesEnhanced.size(); i++) {
        const PPTSlideDataEnhanced& slide = slidesEnhanced[i];
        auto picShapes = slide.getPictureShapes();
        auto textShapes = slide.getTextShapes();

        // Slide relationships file (for images and slide layout)
        std::string slideRels =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>\n";

        int imageRelId = 2;  // rId2 onwards for images (rId1 is for slide layout)
        std::map<uint16_t, int> blipToRelId;  // Map BLIP index to relationship ID
        std::map<int, size_t> shapeIdToEmbeddedIdx;  // Map shape ID to embedded image index
        std::map<size_t, int> embeddedToRelId;  // Map embedded image index to relationship ID

        for (auto* shape : picShapes) {
            // Handle embedded images from F122
            if (shape->imageRef.isEmbedded && shape->imageRef.hasImage && !shape->imageRef.embeddedData.empty()) {
                // Add embedded image to collection
                size_t embeddedIdx = embeddedImages.size();
                embeddedImages.push_back(shape->imageRef.embeddedData);

                // Track shape ID to embedded index
                shapeIdToEmbeddedIdx[shape->shapeId] = embeddedIdx;

                // Determine image type from content
                std::string ext = "png";
                if (shape->imageRef.embeddedData.size() > 4 &&
                    shape->imageRef.embeddedData[0] == 0xFF && shape->imageRef.embeddedData[1] == 0xD8) {
                    ext = "jpg";
                }

                std::string imagePath = "../media/embedded" + std::to_string(embeddedIdx + 1) + "." + ext;
                slideRels += "<Relationship Id=\"rId" + std::to_string(imageRelId) + "\" "
                            "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" "
                            "Target=\"" + imagePath + "\"/>\n";
                embeddedToRelId[embeddedIdx] = imageRelId;
                imageRelId++;
            }
            // Handle images from Pictures stream (blipIndex)
            else if (shape->imageRef.blipIndex < images.size()) {
                const auto& blipImg = images[shape->imageRef.blipIndex];
                std::string ext;
                if (blipImg.type == BLIP_JPEG) ext = "jpg";
                else if (blipImg.type == BLIP_EMF) ext = "emf";
                else if (blipImg.type == BLIP_WMF) ext = "wmf";
                else ext = "png";
                std::string imagePath = "../media/image" + std::to_string(shape->imageRef.blipIndex + 1) + "." + ext;
                slideRels += "<Relationship Id=\"rId" + std::to_string(imageRelId) + "\" "
                            "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" "
                            "Target=\"" + imagePath + "\"/>\n";
                blipToRelId[shape->imageRef.blipIndex] = imageRelId;
                imageRelId++;
            }
        }

        slideRels += "</Relationships>";
        OH_LOG_INFO(LOG_APP, "PPT: Slide %{public}d relationships: %{public}d picture shapes, %{public}d bytes",
                    (int)(i + 1), (int)picShapes.size(), (int)slideRels.size());
        pptxFiles.push_back({"ppt/slides/_rels/slide" + std::to_string(i + 1) + ".xml.rels",
                             std::vector<uint8_t>(slideRels.begin(), slideRels.end())});

        // Slide XML with proper shape elements and background
        std::string slideXml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            "<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">\n"
            "<p:cSld>\n"
            "<p:bg><p:bgPr><a:gradFill rotWithShape=\"true\">"
            "<a:gsLst>"
            "<a:gs pos=\"0\"><a:srgbClr val=\"0B1C3D\"><a:alpha val=\"100000\"/></a:srgbClr></a:gs>"
            "<a:gs pos=\"100000\"><a:srgbClr val=\"17386D\"><a:alpha val=\"100000\"/></a:srgbClr></a:gs>"
            "</a:gsLst>"
            "<a:lin ang=\"2700000\"/>"
            "</a:gradFill></p:bgPr></p:bg>\n"
            "<p:spTree>\n"
            "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\n"
            "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>\n";

        // Add all shapes (text + pictures + connectors)
        for (const auto& shape : slide.shapes) {
            // Use actual position from transform
            int32_t x = shape.transform.x > 0 ? shape.transform.x : 457200;
            int32_t y = shape.transform.y > 0 ? shape.transform.y : 914400;
            int32_t cx = shape.transform.cx > 0 ? shape.transform.cx : 8229600;
            int32_t cy = shape.transform.cy > 0 ? shape.transform.cy : 457200;

            if (shape.isPictureShape && shape.imageRef.hasImage) {
                // Picture shape - use <p:pic> element
                int rId = 2;
                std::string picName = "Picture";
                std::string ext = "png";

                // Handle embedded images from F122
                if (shape.imageRef.isEmbedded && !shape.imageRef.embeddedData.empty()) {
                    size_t embeddedIdx = 0;
                    if (shapeIdToEmbeddedIdx.count(shape.shapeId)) {
                        embeddedIdx = shapeIdToEmbeddedIdx[shape.shapeId];
                    }

                    if (embeddedToRelId.count(embeddedIdx)) {
                        rId = embeddedToRelId[embeddedIdx];
                    }

                    if (shape.imageRef.embeddedData.size() > 4 &&
                        shape.imageRef.embeddedData[0] == 0xFF && shape.imageRef.embeddedData[1] == 0xD8) {
                        ext = "jpg";
                    }

                    picName = "Embedded " + std::to_string(embeddedIdx + 1);
                }
                // Handle images from Pictures stream
                else if (shape.imageRef.blipIndex < images.size()) {
                    if (blipToRelId.count(shape.imageRef.blipIndex)) {
                        rId = blipToRelId[shape.imageRef.blipIndex];
                    }
                    ext = (images[shape.imageRef.blipIndex].type == BLIP_JPEG) ? "jpg" : "png";
                    picName = "Picture " + std::to_string(shape.imageRef.blipIndex + 1);
                }

                slideXml += "<p:pic>\n"
                           "<p:nvPicPr>\n"
                           "<p:cNvPr id=\"" + std::to_string(shape.shapeId) + "\" name=\"" + picName + "." + ext + "\"/>\n"
                           "<p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr>\n"
                           "<p:nvPr/>\n"
                           "</p:nvPicPr>\n"
                           "<p:blipFill>\n"
                           "<a:blip r:embed=\"rId" + std::to_string(rId) + "\"/>\n"
                           "<a:stretch><a:fillRect/></a:stretch>\n"
                           "</p:blipFill>\n"
                           "<p:spPr>\n"
                           "<a:xfrm><a:off x=\"" + std::to_string(x) + "\" y=\"" + std::to_string(y) + "\"/>"
                           "<a:ext cx=\"" + std::to_string(cx) + "\" cy=\"" + std::to_string(cy) + "\"/></a:xfrm>\n"
                           "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>\n"
                           "</p:spPr>\n"
                           "</p:pic>\n";

                OH_LOG_INFO(LOG_APP, "PPT: Added picture shape %{public}d with rId %{public}d, pos=(%{public}d,%{public}d), embedded=%{public}d",
                            shape.shapeId, rId, (int)x, (int)y, (int)shape.imageRef.isEmbedded);

            } else if (shape.isConnector) {
                // Connector shape - use <p:cxnSp> element (line/arrow)
                // Connectors don't have display text, just a line between two points
                slideXml += "<p:cxnSp>\n"
                           "<p:nvCxnSpPr><p:cNvPr id=\"" + std::to_string(shape.shapeId) + "\" name=\"" + xmlEscape(shape.shapeName) + "\"/>"
                           "<p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>\n"
                           "<p:spPr>\n"
                           "<a:xfrm><a:off x=\"" + std::to_string(x) + "\" y=\"" + std::to_string(y) + "\"/>"
                           "<a:ext cx=\"" + std::to_string(cx) + "\" cy=\"" + std::to_string(cy) + "\"/></a:xfrm>\n"
                           "<a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom>\n"
                           "</p:spPr>\n"
                           "</p:cxnSp>\n";

                OH_LOG_INFO(LOG_APP, "PPT: Added connector shape %{public}d name='%{public}s' pos=(%{public}d,%{public}d)",
                            shape.shapeId, shape.shapeName.substr(0,20).c_str(), (int)x, (int)y);

            } else if (!shape.isTextShape && !shape.imageRef.hasImage && !shape.isConnector) {
                // Background/decorative shape with fill color - use <p:sp> with solidFill
                std::string fillXml;
                if (shape.style.hasFill && shape.style.fillColor != 0xFFFFFFFF) {
                    // Convert RGB to RRGGBB hex (skip alpha byte)
                    uint8_t r = (shape.style.fillColor >> 16) & 0xFF;
                    uint8_t g = (shape.style.fillColor >> 8) & 0xFF;
                    uint8_t b = shape.style.fillColor & 0xFF;
                    char colorHex[8];
                    snprintf(colorHex, sizeof(colorHex), "%02X%02X%02X", r, g, b);
                    fillXml = "<a:solidFill><a:srgbClr val=\"" + std::string(colorHex) + "\"/></a:solidFill>\n";
                }

                std::string lineXml;
                if (shape.style.hasLine) {
                    uint8_t lr = (shape.style.lineColor >> 16) & 0xFF;
                    uint8_t lg = (shape.style.lineColor >> 8) & 0xFF;
                    uint8_t lb = shape.style.lineColor & 0xFF;
                    char lcolorHex[8];
                    snprintf(lcolorHex, sizeof(lcolorHex), "%02X%02X%02X", lr, lg, lb);
                    lineXml = "<a:ln w=\"" + std::to_string(shape.style.lineWidth) + "\">"
                              "<a:solidFill><a:srgbClr val=\"" + std::string(lcolorHex) + "\"/></a:solidFill></a:ln>\n";
                }

                slideXml += "<p:sp>\n"
                           "<p:nvSpPr><p:cNvPr id=\"" + std::to_string(shape.shapeId) + "\" name=\"" + xmlEscape(shape.shapeName) + "\"/>"
                           "<p:cNvSpPr/><p:nvPr/></p:nvSpPr>\n"
                           "<p:spPr>\n"
                           "<a:xfrm><a:off x=\"" + std::to_string(x) + "\" y=\"" + std::to_string(y) + "\"/>"
                           "<a:ext cx=\"" + std::to_string(cx) + "\" cy=\"" + std::to_string(cy) + "\"/></a:xfrm>\n"
                           "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>\n"
                           + fillXml + lineXml +
                           "</p:spPr>\n"
                           "</p:sp>\n";

                OH_LOG_INFO(LOG_APP, "PPT: Added background shape %{public}d name='%{public}s' fill=0x%{public}06X pos=(%{public}d,%{public}d)",
                            shape.shapeId, shape.shapeName.substr(0,20).c_str(),
                            shape.style.fillColor, (int)x, (int)y);

            } else if (shape.isTextShape && !shape.text.empty()) {
                // Text shape - use <p:sp> element with formatting
                std::string txBodyContent = "<a:bodyPr anchor=\"ctr\" rtlCol=\"false\" wrap=\"square\" lIns=\"0\" rIns=\"0\" tIns=\"0\" bIns=\"0\"/><a:lstStyle/>\n";

                // Build run properties with font, size, bold, color
                std::string rPrAttrs = "lang=\"en-US\"";
                if (shape.textFmt.isBold) {
                    rPrAttrs += " b=\"true\"";
                }
                rPrAttrs += " sz=\"" + std::to_string(shape.textFmt.fontSize) + "\"";

                // Text color
                std::string colorXml;
                if (shape.textFmt.hasTextColor) {
                    uint8_t tr = (shape.textFmt.textColor >> 16) & 0xFF;
                    uint8_t tg = (shape.textFmt.textColor >> 8) & 0xFF;
                    uint8_t tb = shape.textFmt.textColor & 0xFF;
                    char tcolorHex[8];
                    snprintf(tcolorHex, sizeof(tcolorHex), "%02X%02X%02X", tr, tg, tb);
                    colorXml = "<a:solidFill><a:srgbClr val=\"" + std::string(tcolorHex) + "\"/></a:solidFill>";
                }

                // Font typeface
                std::string fontXml = "<a:latin typeface=\"" + shape.textFmt.fontName + "\"/>"
                                     "<a:ea typeface=\"" + shape.textFmt.fontName + "\"/>";

                std::string fullRPr = "<a:rPr " + rPrAttrs + ">" + colorXml + fontXml + "</a:rPr>";

                // Split text on newlines into separate paragraphs
                std::string remaining = shape.text;

                // Determine alignment based on shape width
                bool isWide = cx > g_slideWidthEmu * 7 / 10;
                std::string alignAttr = isWide ? " algn=\"ctr\"" : "";

                while (!remaining.empty()) {
                    size_t nlPos = remaining.find('\n');
                    std::string line = (nlPos != std::string::npos) ? remaining.substr(0, nlPos) : remaining;
                    txBodyContent += "<a:p><a:pPr" + alignAttr + "><a:defRPr/></a:pPr>"
                                    "<a:r>" + fullRPr + "<a:t>" + xmlEscape(line) + "</a:t></a:r></a:p>\n";
                    if (nlPos != std::string::npos) {
                        remaining = remaining.substr(nlPos + 1);
                    } else {
                        remaining.clear();
                    }
                }

                slideXml += "<p:sp>\n"
                           "<p:nvSpPr><p:cNvPr id=\"" + std::to_string(shape.shapeId) + "\" name=\"" + xmlEscape(shape.shapeName) + "\"/>"
                           "<p:cNvSpPr/><p:nvPr/></p:nvSpPr>\n"
                           "<p:spPr>\n"
                           "<a:xfrm><a:off x=\"" + std::to_string(x) + "\" y=\"" + std::to_string(y) + "\"/>"
                           "<a:ext cx=\"" + std::to_string(cx) + "\" cy=\"" + std::to_string(cy) + "\"/></a:xfrm>\n"
                           "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>\n"
                           "<a:noFill/><a:ln><a:noFill/></a:ln>\n"
                           "</p:spPr>\n"
                           "<p:txBody>\n"
                           + txBodyContent +
                           "</p:txBody>\n"
                           "</p:sp>\n";

                OH_LOG_INFO(LOG_APP, "PPT: Added text shape %{public}d pos=(%{public}d,%{public}d): '%{public}s'",
                            shape.shapeId, (int)x, (int)y, shape.text.substr(0,30).c_str());
            }
        }

        slideXml += "</p:spTree>\n"
                   "</p:cSld>\n"
                   "<p:clrMapOvr>\n"
                   "<a:masterClrMapping bg1=\"lt1\" bg2=\"lt2\" tx1=\"dk1\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>\n"
                   "</p:clrMapOvr>\n"
                   "</p:sld>";

        pptxFiles.push_back({"ppt/slides/slide" + std::to_string(i + 1) + ".xml",
                             std::vector<uint8_t>(slideXml.begin(), slideXml.end())});
    }

    // Add images from Pictures stream to pptxFiles
    for (const auto& img : images) {
        std::string ext;
        if (img.type == BLIP_JPEG) ext = "jpg";
        else if (img.type == BLIP_EMF) ext = "emf";
        else if (img.type == BLIP_WMF) ext = "wmf";
        else ext = "png";
        std::string filename = "ppt/media/image" + std::to_string(img.index + 1) + "." + ext;
        pptxFiles.push_back({filename, img.data});
        OH_LOG_INFO(LOG_APP, "PPT: Added image %{public}s, size=%{public}d",
                    filename.c_str(), (int)img.data.size());
    }

    // Add embedded images from F122 OLE packages to pptxFiles
    for (size_t i = 0; i < embeddedImages.size(); i++) {
        const auto& imgData = embeddedImages[i];
        std::string ext = "png";
        if (imgData.size() > 4 && imgData[0] == 0xFF && imgData[1] == 0xD8) {
            ext = "jpg";
        }
        std::string filename = "ppt/media/embedded" + std::to_string(i + 1) + "." + ext;
        pptxFiles.push_back({filename, imgData});
        OH_LOG_INFO(LOG_APP, "PPT: Added embedded image %{public}s, size=%{public}d",
                    filename.c_str(), (int)imgData.size());
    }

    // Create ZIP output
    OH_LOG_INFO(LOG_APP, "PPT: Creating PPTX with %{public}d files (images:%{public}d, embedded:%{public}d)",
                (int)pptxFiles.size(), (int)images.size(), (int)embeddedImages.size());
    if (!createZIP(outputPath, pptxFiles)) {
        result.errorMsg = "Failed to create ZIP output";
        return false;
    }

    result.success = true;
    result.outputPath = outputPath;
    result.pageCount = slidesEnhanced.size();
    return true;
}

// ============================================================================
// ZIP Packaging with CRC32 calculation
// ============================================================================

// CRC32 lookup table (IEEE 802.3 standard, 256 entries)
static const uint32_t CRC32_TABLE[256] = {
    0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA, 0x076DC419, 0x706AF48F, 0xE963A535, 0x9E6495A3,
    0x0EDB8832, 0x79DCB8A4, 0xE0D5E91E, 0x97D2D988, 0x09B64C2B, 0x7EB17CBD, 0xE7B82D07, 0x90BF1D91,
    0x1DB71064, 0x6AB020F2, 0xF3B97148, 0x84BE41DE, 0x1ADAD47D, 0x6DDDE4EB, 0xF4D4B551, 0x83D385C7,
    0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC, 0x14015C4F, 0x63066CD9, 0xFA0F3D63, 0x8D080DF5,
    0x3B6E20C8, 0x4C69105E, 0xD56041E4, 0xA2677172, 0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B,
    0x35B5A8FA, 0x42B2986C, 0xDBBBC9D6, 0xACBCF940, 0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59,
    0x26D930AC, 0x51DE003A, 0xC8D75180, 0xBFD06116, 0x21B4F4B5, 0x56B3C423, 0xCFBA9599, 0xB8BDA50F,
    0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924, 0x2F6F7C87, 0x58684C11, 0xC1611DAB, 0xB6662D3D,
    0x76DC4190, 0x01DB7106, 0x98D220BC, 0xEFD5102A, 0x71B18589, 0x06B6B51F, 0x9FBFE4A5, 0xE8B8D433,
    0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818, 0x7F6A0DBB, 0x086D3D2D, 0x91646C97, 0xE6635C01,
    0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E, 0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457,
    0x65B0D9C6, 0x12B7E950, 0x8BBEB8EA, 0xFCB9887C, 0x62DD1DDF, 0x15DA2D49, 0x8CD37CF3, 0xFBD44C65,
    0x4DB26158, 0x3AB551CE, 0xA3BC0074, 0xD4BB30E2, 0x4ADFA541, 0x3DD895D7, 0xA4D1C46D, 0xD3D6F4FB,
    0x4369E96A, 0x346ED9FC, 0xAD678846, 0xDA60B8D0, 0x44042D73, 0x33031DE5, 0xAA0A4C5F, 0xDD0D7CC9,
    0x5005713C, 0x270241AA, 0xBE0B1010, 0xC90C2086, 0x5768B525, 0x206F85B3, 0xB966D409, 0xCE61E49F,
    0x5EDEF90E, 0x29D9C998, 0xB0D09822, 0xC7D7A8B4, 0x59B33D17, 0x2EB40D81, 0xB7BD5C3B, 0xC0BA6CAD,
    0xEDB88320, 0x9ABFB3B6, 0x03B6E20C, 0x74B1D29A, 0xEAD54739, 0x9DD277AF, 0x04DB2615, 0x73DC1683,
    0xE3630B12, 0x94643B84, 0x0D6D6A3E, 0x7A6A5AA8, 0xE40ECF0B, 0x9309FF9D, 0x0A00AE27, 0x7D079EB1,
    0xF00F9344, 0x8708A3D2, 0x1E01F268, 0x6906C2FE, 0xF762575D, 0x806567CB, 0x196C3671, 0x6E6B06E7,
    0xFED41B76, 0x89D32BE0, 0x10DA7A5A, 0x67DD4ACC, 0xF9B9DF6F, 0x8EBEEFF9, 0x17B7BE43, 0x60B08ED5,
    0xD6D6A3E8, 0xA1D1937E, 0x38D8C2C4, 0x4FDFF252, 0xD1BB67F1, 0xA6BC5767, 0x3FB506DD, 0x48B2364B,
    0xD80D2BDA, 0xAF0A1B4C, 0x36034AF6, 0x41047A60, 0xDF60EFC3, 0xA867DF55, 0x316E8EEF, 0x4669BE79,
    0xCB61B38C, 0xBC66831A, 0x256FD2A0, 0x5268E236, 0xCC0C7795, 0xBB0B4703, 0x220216B9, 0x5505262F,
    0xC5BA3BBE, 0xB2BD0B28, 0x2BB45A92, 0x5CB36A04, 0xC2D7FFA7, 0xB5D0CF31, 0x2CD99E8B, 0x5BDEAE1D,
    0x9B64C2B0, 0xEC63F226, 0x756AA39C, 0x026D930A, 0x9C0906A9, 0xEB0E363F, 0x72076785, 0x05005713,
    0x95BF4A82, 0xE2B87A14, 0x7BB12BAE, 0x0CB61B38, 0x92D28E9B, 0xE5D5BE0D, 0x7CDCEFB7, 0x0BDBDF21,
    0x86D3D2D4, 0xF1D4E242, 0x68DDB3F8, 0x1FDA836E, 0x81BE16CD, 0xF6B9265B, 0x6FB077E1, 0x18B74777,
    0x88085AE6, 0xFF0F6A70, 0x66063BCA, 0x11010B5C, 0x8F659EFF, 0xF862AE69, 0x616BFFD3, 0x166CCF45,
    0xA00AE278, 0xD70DD2EE, 0x4E048354, 0x3903B3C2, 0xA7672661, 0xD06016F7, 0x4969474D, 0x3E6E77DB,
    0xAED16A4A, 0xD9D65ADC, 0x40DF0B66, 0x37D83BF0, 0xA9BCAE53, 0xDEBB9EC5, 0x47B2CF7F, 0x30B5FFE9,
    0xBDBDF21C, 0xCABAC28A, 0x53B39330, 0x24B4A3A6, 0xBAD03605, 0xCDD70693, 0x54DE5729, 0x23D967BF,
    0xB3667A2E, 0xC4614AB8, 0x5D681B02, 0x2A6F2B94, 0xB40BBE37, 0xC30C8EA1, 0x5A05DF1B, 0x2D02EF8D,
};

// Calculate CRC32 for data
static uint32_t calculateCRC32(const uint8_t* data, size_t size) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < size; i++) {
        crc = CRC32_TABLE[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

bool OfficeConverter::createZIP(const std::string& outputPath,
                                const std::vector<std::pair<std::string, std::vector<uint8_t>>>& files) {
    FILE* zipFile = fopen(outputPath.c_str(), "wb");
    if (!zipFile) return false;

    std::vector<uint32_t> localHeaderOffsets;
    std::vector<uint32_t> fileCRCs;
    std::vector<uint32_t> fileSizes;

    // Write local file headers (STORED - no compression)
    for (const auto& [name, data] : files) {
        // Calculate CRC32 for this file
        uint32_t crc = calculateCRC32(data.data(), data.size());

        uint32_t offset = ftell(zipFile);
        localHeaderOffsets.push_back(offset);
        fileCRCs.push_back(crc);
        fileSizes.push_back(data.size());

        // Local file header signature
        uint32_t signature = 0x04034B50;
        fwrite(&signature, 4, 1, zipFile);

        // Version needed (2.0)
        uint16_t version = 20;
        fwrite(&version, 2, 1, zipFile);

        // General purpose bit flag
        uint16_t flags = 0;
        fwrite(&flags, 2, 1, zipFile);

        // Compression method (0 = STORED)
        uint16_t method = 0;
        fwrite(&method, 2, 1, zipFile);

        // Last mod time/date (placeholder)
        uint16_t modTime = 0;
        uint16_t modDate = 0;
        fwrite(&modTime, 2, 1, zipFile);
        fwrite(&modDate, 2, 1, zipFile);

        // CRC-32 (calculated)
        fwrite(&crc, 4, 1, zipFile);

        // Compressed size
        uint32_t compressedSize = data.size();
        fwrite(&compressedSize, 4, 1, zipFile);

        // Uncompressed size
        uint32_t uncompressedSize = data.size();
        fwrite(&uncompressedSize, 4, 1, zipFile);

        // File name length
        uint16_t nameLen = name.length();
        fwrite(&nameLen, 2, 1, zipFile);

        // Extra field length
        uint16_t extraLen = 0;
        fwrite(&extraLen, 2, 1, zipFile);

        // File name
        fwrite(name.c_str(), nameLen, 1, zipFile);

        // File data
        fwrite(data.data(), data.size(), 1, zipFile);
    }

    // Write central directory
    uint32_t centralDirOffset = ftell(zipFile);

    for (size_t i = 0; i < files.size(); i++) {
        const auto& [name, data] = files[i];
        uint32_t crc = fileCRCs[i];

        // Central directory header signature
        uint32_t signature = 0x02014B50;
        fwrite(&signature, 4, 1, zipFile);

        // Version made by
        uint16_t versionMadeBy = 20;
        fwrite(&versionMadeBy, 2, 1, zipFile);

        // Version needed
        uint16_t versionNeeded = 20;
        fwrite(&versionNeeded, 2, 1, zipFile);

        // General purpose bit flag
        uint16_t flags = 0;
        fwrite(&flags, 2, 1, zipFile);

        // Compression method
        uint16_t method = 0;
        fwrite(&method, 2, 1, zipFile);

        // Last mod time/date
        uint16_t modTime = 0;
        uint16_t modDate = 0;
        fwrite(&modTime, 2, 1, zipFile);
        fwrite(&modDate, 2, 1, zipFile);

        // CRC-32 (calculated)
        fwrite(&crc, 4, 1, zipFile);

        // Compressed size
        uint32_t compressedSize = data.size();
        fwrite(&compressedSize, 4, 1, zipFile);

        // Uncompressed size
        uint32_t uncompressedSize = data.size();
        fwrite(&uncompressedSize, 4, 1, zipFile);

        // File name length
        uint16_t nameLen = name.length();
        fwrite(&nameLen, 2, 1, zipFile);

        // Extra field length
        uint16_t extraLen = 0;
        fwrite(&extraLen, 2, 1, zipFile);

        // File comment length
        uint16_t commentLen = 0;
        fwrite(&commentLen, 2, 1, zipFile);

        // Disk number start
        uint16_t diskNum = 0;
        fwrite(&diskNum, 2, 1, zipFile);

        // Internal file attributes
        uint16_t internalAttr = 0;
        fwrite(&internalAttr, 2, 1, zipFile);

        // External file attributes
        uint32_t externalAttr = 0;
        fwrite(&externalAttr, 4, 1, zipFile);

        // Relative offset of local header
        uint32_t localOffset = localHeaderOffsets[i];
        fwrite(&localOffset, 4, 1, zipFile);

        // File name
        fwrite(name.c_str(), nameLen, 1, zipFile);
    }

    // Write end of central directory
    uint32_t centralDirSize = ftell(zipFile) - centralDirOffset;

    // EOCD signature
    uint32_t eocdSignature = 0x06054B50;
    fwrite(&eocdSignature, 4, 1, zipFile);

    // Number of this disk
    uint16_t diskNum = 0;
    fwrite(&diskNum, 2, 1, zipFile);

    // Disk where central directory starts
    uint16_t centralDirDisk = 0;
    fwrite(&centralDirDisk, 2, 1, zipFile);

    // Number of central directory records on this disk
    uint16_t numRecordsDisk = files.size();
    fwrite(&numRecordsDisk, 2, 1, zipFile);

    // Total number of central directory records
    uint16_t totalRecords = files.size();
    fwrite(&totalRecords, 2, 1, zipFile);

    // Size of central directory
    uint32_t centralDirSizeField = centralDirSize;
    fwrite(&centralDirSizeField, 4, 1, zipFile);

    // Offset of start of central directory
    uint32_t centralDirOffsetField = centralDirOffset;
    fwrite(&centralDirOffsetField, 4, 1, zipFile);

    // Comment length
    uint16_t commentLen = 0;
    fwrite(&commentLen, 2, 1, zipFile);

    fclose(zipFile);
    return true;
}