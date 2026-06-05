/*
 * DOCX Writer - OOXML Table/Image Export + ZIP Packaging
 *
 * Simplified implementation based on LibreOffice docxtableexport.cxx
 * ZIP packaging using raw fwrite (no external libzip dependency)
 *
 * OOXML Table Structure:
 * <w:tbl>
 *   <w:tblPr>...</w:tblPr>
 *   <w:tblGrid>
 *     <w:gridCol w:w="width"/>
 *   </w:tblGrid>
 *   <w:tr>
 *     <w:tc>
 *       <w:tcPr><w:gridSpan w:val="n"/></w:tcPr>
 *       <w:p><w:r><w:t>text</w:t></w:r></w:p>
 *     </w:tc>
 *   </w:tr>
 * </w:tbl>
 */

#ifndef DOCX_WRITER_HPP
#define DOCX_WRITER_HPP

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <zlib.h>
#include <hilog/log.h>
#include "ww8_structs.hpp"

// ============================================================================
// CRC32 Calculation using zlib (inline wrapper)
// ============================================================================

inline uint32_t docxCalculateCRC32(const uint8_t* data, size_t size) {
    if (data == nullptr || size == 0) {
        return 0;
    }
    return crc32(0L, data, static_cast<uInt>(size));
}

// Safe string to vector conversion - avoid iterator constructor issues
inline std::vector<uint8_t> stringToVector(const std::string& str) {
    std::vector<uint8_t> result;
    if (str.size() > 0) {
        result.resize(str.size());
        std::memcpy(result.data(), str.data(), str.size());
    }
    return result;
}

// ============================================================================
// OOXML Helper Functions
// ============================================================================

inline std::string docxXmlEscape(const std::string& text) {
    std::string result;
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

// ============================================================================
// DOCX Content Builder
// ============================================================================

class DocxContentBuilder {
public:
    DocxContentBuilder() : m_imageCount(0) {
        m_documentXml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"\n"
            "            xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"\n"
            "            xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"\n"
            "            xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"\n"
            "            xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\n"
            "<w:body>\n";
    }

    void addParagraph(const std::string& text) {
        if (text.empty()) {
            m_documentXml += "<w:p/>\n";
        } else {
            m_documentXml += "<w:p><w:r><w:t>" + docxXmlEscape(text) + "</w:t></w:r></w:p>\n";
        }
    }

    void startTable() {
        m_documentXml += "<w:tbl>\n";
    }

    void addTableProperties(const std::vector<int16_t>& colWidths) {
        // tblPr - basic properties
        m_documentXml += "<w:tblPr>\n";
        m_documentXml += "<w:tblStyle w:val=\"TableNormal\"/>\n";
        m_documentXml += "<w:tblW w:w=\"0\" w:type=\"auto\"/>\n";
        // Table borders
        m_documentXml += "<w:tblBorders>\n"
            "<w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>\n"
            "<w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>\n"
            "<w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>\n"
            "<w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>\n"
            "<w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>\n"
            "<w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>\n"
            "</w:tblBorders>\n";
        m_documentXml += "</w:tblPr>\n";

        // tblGrid - column widths (in twips)
        m_documentXml += "<w:tblGrid>\n";
        for (size_t i = 0; i + 1 < colWidths.size(); i++) {
            int width = abs(colWidths[i + 1] - colWidths[i]);
            m_documentXml += "<w:gridCol w:w=\"" + std::to_string(width) + "\"/>\n";
        }
        m_documentXml += "</w:tblGrid>\n";
    }

    void startRow() {
        m_documentXml += "<w:tr>\n";
    }

    void endRow() {
        m_documentXml += "</w:tr>\n";
    }

    void addCell(const std::string& text, int gridSpan = 1, bool vertMerge = false) {
        m_documentXml += "<w:tc>\n";

        // tcPr - cell properties
        if (gridSpan > 1 || vertMerge) {
            m_documentXml += "<w:tcPr>\n";
            if (gridSpan > 1) {
                m_documentXml += "<w:gridSpan w:val=\"" + std::to_string(gridSpan) + "\"/>\n";
            }
            if (vertMerge) {
                m_documentXml += "<w:vMerge w:val=\"continue\"/>\n";
            }
            m_documentXml += "</w:tcPr>\n";
        }

        // Cell content
        if (text.empty()) {
            m_documentXml += "<w:p/>\n";
        } else {
            m_documentXml += "<w:p><w:r><w:t>" + docxXmlEscape(text) + "</w:t></w:r></w:p>\n";
        }

        m_documentXml += "</w:tc>\n";
    }

    void endTable() {
        m_documentXml += "</w:tbl>\n";
    }

    // Add inline image (OOXML drawing element)
    // rId refers to the relationship ID in word/_rels/document.xml.rels
    void addImage(const ImageInfo& img, int rIdIndex) {
        m_imageCount++;
        std::string rId = "rId" + std::to_string(rIdIndex);
        std::string imgName = "Picture " + std::to_string(m_imageCount);

        int cx = img.widthEmu > 0 ? img.widthEmu : 5232400;
        int cy = img.heightEmu > 0 ? img.heightEmu : 4387850;

        std::ostringstream xml;
        xml << "<w:p>"
            << "<w:r>"
            << "<w:rPr><w:noProof/></w:rPr>"
            << "<w:drawing>"
            << "<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
            << "<wp:extent cx=\"" << cx << "\" cy=\"" << cy << "\"/>"
            << "<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
            << "<wp:docPr id=\"" << m_imageCount << "\" name=\"" << imgName << "\"/>"
            << "<wp:cNvGraphicFramePr>"
            << "<a:graphicFrameLocks xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" noChangeAspect=\"1\"/>"
            << "</wp:cNvGraphicFramePr>"
            << "<a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">"
            << "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            << "<pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
            << "<pic:nvPicPr>"
            << "<pic:cNvPr id=\"" << m_imageCount << "\" name=\"" << imgName << "\"/>"
            << "<pic:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></pic:cNvPicPr>"
            << "</pic:nvPicPr>"
            << "<pic:blipFill>"
            << "<a:blip r:embed=\"" << rId << "\"/>"
            << "<a:stretch><a:fillRect/></a:stretch>"
            << "</pic:blipFill>"
            << "<pic:spPr bwMode=\"auto\">"
            << "<a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"" << cx << "\" cy=\"" << cy << "\"/></a:xfrm>"
            << "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
            << "</pic:spPr>"
            << "</pic:pic>"
            << "</a:graphicData>"
            << "</a:graphic>"
            << "</wp:inline>"
            << "</w:drawing>"
            << "</w:r>"
            << "</w:p>\n";

        m_documentXml += xml.str();
    }

    void finalize() {
        m_documentXml += "</w:body>\n</w:document>\n";
    }

    std::string getDocumentXml() const {
        return m_documentXml;
    }

    int getImageCount() const { return m_imageCount; }

private:
    std::string m_documentXml;
    int m_imageCount;
};

// ============================================================================
// ZIP Writer (simple implementation using fwrite, no libzip)
// ============================================================================

class DocxZipWriter {
public:
    bool createArchive(const std::string& filepath,
                       const std::string& documentXml,
                       const std::vector<ImageInfo>& images) {
        FILE* zipFile = fopen(filepath.c_str(), "wb");
        if (!zipFile) {
            OH_LOG_ERROR(LOG_APP, "DocxZipWriter: Failed to create ZIP file %{public}s", filepath.c_str());
            return false;
        }

        // Collect all files to add to ZIP
        std::vector<std::pair<std::string, std::vector<uint8_t>>> files;
        files.reserve(3 + images.size() + 2);

        // Build content types
        std::string contentTypes =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n"
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n"
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>\n";

        bool hasPng = false, hasJpeg = false;
        for (const auto& img : images) {
            if (img.format == "png") hasPng = true;
            if (img.format == "jpeg") hasJpeg = true;
        }
        if (hasPng) contentTypes += "<Default Extension=\"png\" ContentType=\"image/png\"/>\n";
        if (hasJpeg) contentTypes += "<Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>\n";

        contentTypes += "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>\n</Types>\n";
        files.push_back({"[Content_Types].xml", stringToVector(contentTypes)});

        // _rels/.rels
        std::string rels =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>\n</Relationships>\n";
        files.push_back({"_rels/.rels", stringToVector(rels)});

        // word/_rels/document.xml.rels
        std::ostringstream docRels;
        docRels << "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                << "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n";
        for (size_t i = 0; i < images.size(); i++) {
            int rId = static_cast<int>(i) + 2;
            std::string ext = images[i].format;
            docRels << "<Relationship Id=\"rId" << rId << "\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image" << (i + 1) << "." << ext << "\"/>\n";
        }
        docRels << "</Relationships>\n";
        files.push_back({"word/_rels/document.xml.rels", stringToVector(docRels.str())});

        // Add image files
        for (size_t i = 0; i < images.size(); i++) {
            std::string path = "word/media/image" + std::to_string(i + 1) + "." + images[i].format;
            files.emplace_back(std::make_pair(path, images[i].data));
        }

        // word/document.xml
        files.push_back({"word/document.xml", stringToVector(documentXml)});

        // Write ZIP
        std::vector<uint32_t> localHeaderOffsets;
        std::vector<uint32_t> fileCRCs;
        std::vector<uint32_t> fileSizes;

        for (const auto& [name, data] : files) {
            uint32_t crc = docxCalculateCRC32(data.data(), data.size());
            localHeaderOffsets.push_back(ftell(zipFile));
            fileCRCs.push_back(crc);
            fileSizes.push_back(data.size());

            uint32_t signature = 0x04034B50;
            fwrite(&signature, 4, 1, zipFile);
            uint16_t version = 20;
            fwrite(&version, 2, 1, zipFile);
            uint16_t flags = 0;
            fwrite(&flags, 2, 1, zipFile);
            uint16_t method = 0;
            fwrite(&method, 2, 1, zipFile);
            uint16_t modTime = 0, modDate = 0;
            fwrite(&modTime, 2, 1, zipFile);
            fwrite(&modDate, 2, 1, zipFile);
            fwrite(&crc, 4, 1, zipFile);
            uint32_t compressedSize = data.size();
            fwrite(&compressedSize, 4, 1, zipFile);
            fwrite(&compressedSize, 4, 1, zipFile);
            uint16_t nameLen = static_cast<uint16_t>(name.length());
            fwrite(&nameLen, 2, 1, zipFile);
            uint16_t extraLen = 0;
            fwrite(&extraLen, 2, 1, zipFile);
            fwrite(name.c_str(), nameLen, 1, zipFile);
            fwrite(data.data(), data.size(), 1, zipFile);
        }

        // Central directory starts here
        uint32_t centralDirOffset = ftell(zipFile);

        // Write central directory headers for each file
        for (size_t i = 0; i < files.size(); i++) {
            const auto& [name, data] = files[i];

            // Central directory header signature
            uint32_t cdSignature = 0x02014B50;
            fwrite(&cdSignature, 4, 1, zipFile);

            // Version made by
            uint16_t versionMadeBy = 20;
            fwrite(&versionMadeBy, 2, 1, zipFile);

            // Version needed to extract
            uint16_t versionNeeded = 20;
            fwrite(&versionNeeded, 2, 1, zipFile);

            // General purpose flags
            uint16_t flags = 0;
            fwrite(&flags, 2, 1, zipFile);

            // Compression method (0 = stored)
            uint16_t method = 0;
            fwrite(&method, 2, 1, zipFile);

            // Last mod time and date
            uint16_t modTime = 0, modDate = 0;
            fwrite(&modTime, 2, 1, zipFile);
            fwrite(&modDate, 2, 1, zipFile);

            // CRC-32
            fwrite(&fileCRCs[i], 4, 1, zipFile);

            // Compressed size and uncompressed size
            uint32_t fileSize = fileSizes[i];
            fwrite(&fileSize, 4, 1, zipFile);
            fwrite(&fileSize, 4, 1, zipFile);

            // File name length
            uint16_t nameLen = static_cast<uint16_t>(name.length());
            fwrite(&nameLen, 2, 1, zipFile);

            // Extra field length
            uint16_t extraLen = 0;
            fwrite(&extraLen, 2, 1, zipFile);

            // File comment length
            uint16_t commentLen = 0;
            fwrite(&commentLen, 2, 1, zipFile);

            // Disk number start
            uint16_t diskNumStart = 0;
            fwrite(&diskNumStart, 2, 1, zipFile);

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
        uint16_t numRecordsOnDisk = static_cast<uint16_t>(files.size());
        fwrite(&numRecordsOnDisk, 2, 1, zipFile);

        // Total number of central directory records
        uint16_t totalRecords = static_cast<uint16_t>(files.size());
        fwrite(&totalRecords, 2, 1, zipFile);

        // Size of central directory
        fwrite(&centralDirSize, 4, 1, zipFile);

        // Offset of start of central directory
        fwrite(&centralDirOffset, 4, 1, zipFile);

        // Comment length
        uint16_t commentLen = 0;
        fwrite(&commentLen, 2, 1, zipFile);

        fclose(zipFile);
        std::cout << "DOCX created: " << filepath << std::endl;
        return true;
    }

private:
    // Simple fwrite-based helper (not needed now, handled inline above)
};

// ============================================================================
// DOCX Writer - High-level Interface
// ============================================================================

class DocxWriter {
public:
    DocxWriter() {}

    void writeDocument(const std::vector<DocumentElement>& elements, const std::string& outputPath) {
        OH_LOG_INFO(LOG_APP, "DocxWriter: writeDocument STEP 1 - start, elements=%{public}d, outputPath=%{public}s",
                    (int)elements.size(), outputPath.c_str());

        DocxContentBuilder builder;
        OH_LOG_INFO(LOG_APP, "DocxWriter: writeDocument STEP 2 - builder created");

        // Collect images for embedding
        OH_LOG_INFO(LOG_APP, "DocxWriter: writeDocument STEP 3 - collecting images");
        std::vector<ImageInfo> images;
        int imageIdx = 0;
        for (const auto& elem : elements) {
            if (elem.isImage) {
                // Safety check: limit image size
                if (elem.image.data.size() > 100 * 1024 * 1024) {
                    OH_LOG_WARN(LOG_APP, "DocxWriter: Skipping large image (%{public}d bytes)", (int)elem.image.data.size());
                    continue;
                }
                OH_LOG_INFO(LOG_APP, "DocxWriter: Found image[%{public}d], format=%{public}s, size=%{public}d",
                            imageIdx, elem.image.format.c_str(), (int)elem.image.data.size());
                images.push_back(elem.image);
                imageIdx++;
            }
        }

        OH_LOG_INFO(LOG_APP, "DocxWriter: writeDocument STEP 4 - collected %{public}d images", (int)images.size());

        size_t nextImageIdx = 0;
        int elemIdx = 0;
        OH_LOG_INFO(LOG_APP, "DocxWriter: writeDocument STEP 5 - processing elements");
        for (const auto& elem : elements) {
            elemIdx++;
            OH_LOG_INFO(LOG_APP, "DocxWriter: STEP 5.%{public}d - processing element", elemIdx);
            if (elem.isTable) {
                OH_LOG_INFO(LOG_APP, "DocxWriter: Element[%{public}d] is table, rows=%{public}d",
                            elemIdx, (int)elem.table.rows.size());
                // 详细检查表格数据
                for (int r = 0; r < (int)elem.table.rows.size() && r < 3; r++) {
                    const auto& row = elem.table.rows[r];
                    OH_LOG_INFO(LOG_APP, "DocxWriter: Table row[%{public}d], cells=%{public}d, colBounds=%{public}d",
                                r, (int)row.cells.size(), (int)row.colBoundaries.size());
                }
                OH_LOG_INFO(LOG_APP, "DocxWriter: Element[%{public}d] calling writeTable", elemIdx);
                writeTable(builder, elem.table);
                OH_LOG_INFO(LOG_APP, "DocxWriter: Element[%{public}d] table written OK", elemIdx);
            } else if (elem.isImage) {
                // rId index: images[i] gets rId(i+2) in document.xml.rels
                int rIdIndex = static_cast<int>(nextImageIdx) + 2;
                OH_LOG_INFO(LOG_APP, "DocxWriter: Element[%{public}d] is image, rIdIndex=%{public}d",
                            elemIdx, rIdIndex);
                builder.addImage(elem.image, rIdIndex);
                nextImageIdx++;
                OH_LOG_INFO(LOG_APP, "DocxWriter: Element[%{public}d] image written OK", elemIdx);
            } else {
                OH_LOG_INFO(LOG_APP, "DocxWriter: Element[%{public}d] is paragraph, textLen=%{public}d",
                            elemIdx, (int)elem.text.length());
                builder.addParagraph(elem.text);
                OH_LOG_INFO(LOG_APP, "DocxWriter: Element[%{public}d] paragraph written OK", elemIdx);
            }
        }

        OH_LOG_INFO(LOG_APP, "DocxWriter: writeDocument STEP 6 - all elements processed, calling finalize");
        builder.finalize();
        OH_LOG_INFO(LOG_APP, "DocxWriter: writeDocument STEP 7 - finalize OK, docXmlSize=%{public}d",
                    (int)builder.getDocumentXml().size());

        OH_LOG_INFO(LOG_APP, "DocxWriter: writeDocument STEP 8 - creating zip archive");
        DocxZipWriter zipWriter;
        OH_LOG_INFO(LOG_APP, "DocxWriter: writeDocument STEP 9 - zipWriter created, calling createArchive");
        zipWriter.createArchive(outputPath, builder.getDocumentXml(), images);
        OH_LOG_INFO(LOG_APP, "DocxWriter: writeDocument STEP 10 - createArchive returned OK");
    }

    void writeTables(const std::vector<TableInfo>& tables, const std::string& outputPath) {
        std::vector<DocumentElement> elements;
        for (const auto& table : tables) {
            elements.push_back(DocumentElement::makeTable(table));
        }
        writeDocument(elements, outputPath);
    }

private:
    void writeTable(DocxContentBuilder& builder, const TableInfo& table) {
        builder.startTable();

        if (table.colWidths.size() > 0) {
            builder.addTableProperties(table.colWidths);
        }

        for (const auto& row : table.rows) {
            builder.startRow();

            for (const auto& cell : row.cells) {
                builder.addCell(cell.text, cell.colSpan, cell.vertMerge);
            }

            builder.endRow();
        }

        builder.endTable();
        builder.addParagraph("");  // Paragraph after table
    }
};

#endif // DOCX_WRITER_HPP