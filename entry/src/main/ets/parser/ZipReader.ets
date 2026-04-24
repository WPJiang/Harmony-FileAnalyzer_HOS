/**
 * ZipReader - ZIP file reader for HarmonyOS
 *
 * Parses ZIP file format and extracts file contents.
 * Uses HarmonyOS built-in zlib for DEFLATE decompression.
 */

import { fileIo } from '@kit.CoreFileKit';
import zlib from '@ohos.zlib';

// Interface for sizes passed from Central Directory
interface SizesInfo {
  compressedSize: number;
  uncompressedSize: number;
}

export interface ZipEntry {
  name: string;
  compressedSize: number;  // Original value from header (may be 0 for Data Descriptor)
  uncompressedSize: number;
  compressionMethod: number;
  data: Uint8Array | null;
  actualDataLength?: number;  // Actual compressed data length (used for offset calculation)
}

const LOCAL_FILE_HEADER_SIG = 0x04034b50;
const CENTRAL_DIR_HEADER_SIG = 0x02014b50;
const END_OF_CENTRAL_DIR_SIG = 0x06054b50;
const DEFLATE = 8;
const STORED = 0;

/**
 * Inflate compressed data using HarmonyOS built-in zlib
 * ZIP uses raw deflate (no zlib/gzip header), so windowBits = -15
 * @param compressed Compressed data (Uint8Array)
 * @param expectedSize Expected uncompressed size
 * @returns Decompressed data or null on failure
 */
async function inflate(compressed: Uint8Array, expectedSize: number): Promise<Uint8Array | null> {
  try {
    console.info(`[ZipReader] inflate: compressed=${compressed.length}, expected=${expectedSize}`);

    // Create Zip object for inflate operations
    const zip = zlib.createZipSync();

    // Create output buffer
    const outputBuffer = new ArrayBuffer(expectedSize);

    // Create ZStream directly
    const strm: zlib.ZStream = {
      nextIn: compressed.buffer.slice(compressed.byteOffset, compressed.byteOffset + compressed.length),
      availableIn: compressed.length,
      nextOut: outputBuffer,
      availableOut: expectedSize
    };

    // Initialize inflate with raw deflate mode (windowBits = -15)
    // Raw deflate has no zlib/gzip header, used in ZIP files
    const initResult = await zip.inflateInit2(strm, -15);
    console.info(`[ZipReader] inflateInit2 result: ${initResult}`);

    if (initResult !== zlib.ReturnStatus.OK) {
      console.error(`[ZipReader] inflateInit2 failed: ${initResult}`);
      return null;
    }

    // Perform inflation
    const inflateResult = await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
    console.info(`[ZipReader] inflate result: ${inflateResult}, totalOut=${strm.totalOut}`);

    // End inflate stream
    await zip.inflateEnd(strm);

    if (inflateResult !== zlib.ReturnStatus.STREAM_END && inflateResult !== zlib.ReturnStatus.OK) {
      console.error(`[ZipReader] inflate failed: ${inflateResult}`);
      return null;
    }

    // Check output size
    if (strm.totalOut !== expectedSize) {
      console.warn(`[ZipReader] inflate size mismatch: expected=${expectedSize}, actual=${strm.totalOut}`);
    }

    // Create Uint8Array from output
    const result = new Uint8Array(outputBuffer, 0, strm.totalOut || expectedSize);
    console.info(`[ZipReader] inflate success: output size=${result.length}`);

    return result;
  } catch (err) {
    console.error(`[ZipReader] inflate exception: ${(err as Error).message}`);
    console.error(`[ZipReader] inflate stack: ${(err as Error).stack}`);
    return null;
  }
}

function readUint16LE(bytes: Uint8Array, offset: number): number {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function readUint32LE(bytes: Uint8Array, offset: number): number {
  return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
}

function readString(bytes: Uint8Array, offset: number, length: number): string {
  let result = '';
  for (let i = 0; i < length; i++) {
    const byte = bytes[offset + i];
    if (byte === 0) break;
    result += String.fromCharCode(byte);
  }
  return result;
}

function getLocalFileHeaderSize(bytes: Uint8Array, offset: number): number {
  const fileNameLength = readUint16LE(bytes, offset + 26);
  const extraFieldLength = readUint16LE(bytes, offset + 28);
  return 30 + fileNameLength + extraFieldLength;
}

async function parseLocalFileHeader(bytes: Uint8Array, offset: number, centralDirSizes?: SizesInfo): Promise<ZipEntry | null> {
  try {
    const generalFlag = readUint16LE(bytes, offset + 6);
    const compressionMethod = readUint16LE(bytes, offset + 8);
    const headerCompressedSize = readUint32LE(bytes, offset + 18);
    const headerUncompressedSize = readUint32LE(bytes, offset + 22);
    const fileNameLength = readUint16LE(bytes, offset + 26);
    const extraFieldLength = readUint16LE(bytes, offset + 28);

    const headerSize = 30 + fileNameLength + extraFieldLength;
    const fileName = readString(bytes, offset + 30, fileNameLength);

    // Use Central Directory sizes if provided (more reliable for Data Descriptor mode)
    let compressedSize = headerCompressedSize;
    let uncompressedSize = headerUncompressedSize;
    if (centralDirSizes !== undefined && centralDirSizes !== null) {
      compressedSize = centralDirSizes.compressedSize;
      uncompressedSize = centralDirSizes.uncompressedSize;
    }

    console.info(`[ZipReader] parseLocalFileHeader: "${fileName}", flag=${generalFlag}, method=${compressionMethod}, headerSizes=${headerCompressedSize}/${headerUncompressedSize}, actualSizes=${compressedSize}/${uncompressedSize}`);
    console.info(`[ZipReader] headerSize=${headerSize}, fileNameLength=${fileNameLength}, extraFieldLength=${extraFieldLength}`);

    // Check if Data Descriptor is used (bit 3 of general flag)
    const hasDataDescriptor = (generalFlag & 0x08) !== 0;
    const usingCentralDirSizes = centralDirSizes !== undefined && centralDirSizes !== null;
    console.info(`[ZipReader] hasDataDescriptor: ${hasDataDescriptor}, usingCentralDirSizes: ${usingCentralDirSizes}`);

    let data: Uint8Array | null = null;
    let actualDataLength = compressedSize;  // For offset calculation

    // If we have sizes from Central Directory, use them directly
    if (compressedSize > 0 && uncompressedSize > 0) {
      const dataStart = offset + headerSize;
      console.info(`[ZipReader] offset=${offset}, dataStart=${dataStart}`);

      // Log the bytes at dataStart to verify we're at correct position
      const compressedBytesPreview = bytes.slice(dataStart, dataStart + Math.min(10, compressedSize));
      const compressedBytesStr = Array.from(compressedBytesPreview).map(b => b.toString(16).padStart(2, '0')).join(' ');
      console.info(`[ZipReader] Compressed data at ${dataStart}: ${compressedBytesStr}, length=${compressedSize}`);

      const compressedData = bytes.slice(dataStart, dataStart + compressedSize);

      if (compressionMethod === STORED) {
        data = new Uint8Array(compressedData);
      } else if (compressionMethod === DEFLATE) {
        data = await inflate(new Uint8Array(compressedData), uncompressedSize);
        if (data) {
          // Log preview of inflated data
          const previewBytes = data.slice(0, Math.min(50, data.length));
          const previewStr = Array.from(previewBytes).map(b => b >= 32 && b < 127 ? String.fromCharCode(b) : '.').join('');
          console.info(`[ZipReader] Inflated preview: "${previewStr}"`);
        }
      }
      // For Data Descriptor mode, add 12 or 16 bytes for the descriptor
      if (hasDataDescriptor) {
        // Check if there's a Data Descriptor signature (0x08074b50) after the compressed data
        const ddPos = dataStart + compressedSize;
        if (ddPos + 4 < bytes.length) {
          const ddSig = readUint32LE(bytes, ddPos);
          if (ddSig === 0x08074b50) {
            actualDataLength = compressedSize + 16;  // 16 bytes with signature
          } else {
            actualDataLength = compressedSize + 12;  // 12 bytes without signature
          }
        }
      }
    }

    const result: ZipEntry = {
      name: fileName,
      compressedSize: compressedSize,
      uncompressedSize: uncompressedSize,
      compressionMethod: compressionMethod,
      data: data,
      actualDataLength: actualDataLength
    };

    if (data === null && (compressionMethod === DEFLATE || compressionMethod === STORED)) {
      console.warn(`[ZipReader] Entry "${fileName}" has no data inflated! method=${compressionMethod}, compressed=${compressedSize}, uncompressed=${uncompressedSize}`);
    }

    return result;
  } catch (err) {
    console.error('[ZipReader] Parse header error:', err);
    return null;
  }
}

interface CentralDirEntry {
  fileName: string;
  localHeaderOffset: number;
  compressedSize: number;
  uncompressedSize: number;
  compressionMethod: number;
}

export class ZipReader {
  /**
   * Find End of Central Directory (EOCD) record
   * EOCD is at the end of the file, signature 0x06054b50
   */
  private static findEndOfCentralDir(bytes: Uint8Array): number {
    // EOCD minimum size is 22 bytes, search backwards from end
    // EOCD can have variable-sized comment, so search backwards for signature
    const minEOCDSize = 22;
    const maxCommentSize = 65535;

    // Search backwards from the end
    for (let pos = bytes.length - minEOCDSize; pos >= bytes.length - minEOCDSize - maxCommentSize && pos >= 0; pos--) {
      const sig = readUint32LE(bytes, pos);
      if (sig === END_OF_CENTRAL_DIR_SIG) {
        console.info(`[ZipReader] Found EOCD at offset: ${pos}`);
        return pos;
      }
    }
    console.error('[ZipReader] EOCD not found!');
    return -1;
  }

  /**
   * Parse Central Directory to get entry info including sizes
   * Returns array of CentralDirEntry with offsets and sizes
   */
  private static parseCentralDir(bytes: Uint8Array, eocdOffset: number): CentralDirEntry[] {
    const entries: CentralDirEntry[] = [];

    // Read EOCD fields
    const totalEntries = readUint16LE(bytes, eocdOffset + 10);
    const centralDirSize = readUint32LE(bytes, eocdOffset + 12);
    const centralDirOffset = readUint32LE(bytes, eocdOffset + 16);

    console.info(`[ZipReader] Central Dir: totalEntries=${totalEntries}, size=${centralDirSize}, offset=${centralDirOffset}`);

    // Parse each Central Directory entry
    let offset = centralDirOffset;
    for (let i = 0; i < totalEntries && offset < bytes.length; i++) {
      const sig = readUint32LE(bytes, offset);
      if (sig !== CENTRAL_DIR_HEADER_SIG) {
        console.error(`[ZipReader] Invalid Central Dir entry at offset ${offset}, sig=0x${sig.toString(16)}`);
        break;
      }

      // Central Directory Header structure:
      // 4: signature
      // 2: version made by (offset 4)
      // 2: version needed (offset 6)
      // 2: general purpose bit flag (offset 8)
      // 2: compression method (offset 10)
      // 2: last mod time (offset 12)
      // 2: last mod date (offset 14)
      // 4: CRC-32 (offset 16)
      // 4: compressed size (offset 20)
      // 4: uncompressed size (offset 24)
      // 2: file name length (offset 28)
      // 2: extra field length (offset 30)
      // 2: file comment length (offset 32)
      // 2: disk number start (offset 34)
      // 2: internal file attributes (offset 36)
      // 4: external file attributes (offset 38)
      // 4: relative offset of local header (offset 42)

      const compressionMethod = readUint16LE(bytes, offset + 10);
      const compressedSize = readUint32LE(bytes, offset + 20);
      const uncompressedSize = readUint32LE(bytes, offset + 24);
      const fileNameLength = readUint16LE(bytes, offset + 28);
      const extraFieldLength = readUint16LE(bytes, offset + 30);
      const commentLength = readUint16LE(bytes, offset + 32);
      const localHeaderOffset = readUint32LE(bytes, offset + 42);  // Fixed: offset is 42, not 46

      const fileName = readString(bytes, offset + 46, fileNameLength);
      console.info(`[ZipReader] Central Dir entry ${i}: "${fileName}", localOffset=${localHeaderOffset}, sizes=${compressedSize}/${uncompressedSize}, method=${compressionMethod}`);

      entries.push({
        fileName: fileName,
        localHeaderOffset: localHeaderOffset,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        compressionMethod: compressionMethod
      });

      // Move to next Central Directory entry
      offset += 46 + fileNameLength + extraFieldLength + commentLength;
    }

    return entries;
  }

  static async readZipFile(filePath: string): Promise<Map<string, ZipEntry>> {
    const entries = new Map<string, ZipEntry>();

    console.info(`[ZipReader] ========== START READING ZIP: ${filePath} ==========`);

    try {
      console.info(`[ZipReader] Step 1 - Opening file...`);
      const file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
      console.info(`[ZipReader] Step 1 SUCCESS - File opened, fd: ${file.fd}`);

      const stat = await fileIo.stat(file.fd);
      const fileSize = stat.size;
      console.info(`[ZipReader] Step 2 - File size: ${fileSize} bytes`);

      if (fileSize === 0) {
        console.error(`[ZipReader] Step 2 FAILED - File size is 0!`);
        await fileIo.close(file.fd);
        return entries;
      }

      const buffer = new ArrayBuffer(fileSize);
      console.info(`[ZipReader] Step 3 - Reading file content into buffer...`);

      await fileIo.read(file.fd, buffer);
      await fileIo.close(file.fd);
      console.info(`[ZipReader] Step 3 SUCCESS - File content read`);

      const bytes = new Uint8Array(buffer);

      // Step 4: Find End of Central Directory
      console.info(`[ZipReader] Step 4 - Finding End of Central Directory...`);
      const eocdOffset = ZipReader.findEndOfCentralDir(bytes);
      if (eocdOffset < 0) {
        console.error('[ZipReader] Failed to find EOCD!');
        return entries;
      }

      // Step 5: Parse Central Directory to get entry info
      console.info(`[ZipReader] Step 5 - Parsing Central Directory...`);
      const centralDirEntries = ZipReader.parseCentralDir(bytes, eocdOffset);
      console.info(`[ZipReader] Step 5 SUCCESS - Found ${centralDirEntries.length} entries in Central Directory`);

      // Step 6: Parse each entry using info from Central Directory
      let entryCount = 0;
      let failedInflateCount = 0;

      console.info(`[ZipReader] Step 6 - Parsing entries using Central Directory info...`);

      // Sort entries by offset for ordered processing
      const sortedEntries = centralDirEntries.sort((a, b) => a.localHeaderOffset - b.localHeaderOffset);

      for (const cdEntry of sortedEntries) {
        // Verify signature at local header offset
        const sig = readUint32LE(bytes, cdEntry.localHeaderOffset);
        if (sig !== LOCAL_FILE_HEADER_SIG) {
          console.error(`[ZipReader] Invalid local header at offset ${cdEntry.localHeaderOffset} for "${cdEntry.fileName}", sig=0x${sig.toString(16)}`);
          continue;
        }

        const sizes: SizesInfo = {
          compressedSize: cdEntry.compressedSize,
          uncompressedSize: cdEntry.uncompressedSize
        };
        const entry = await parseLocalFileHeader(bytes, cdEntry.localHeaderOffset, sizes);
        if (entry) {
          entryCount++;
          console.info(`[ZipReader] Entry ${entryCount}: "${entry.name}", compressed=${entry.compressedSize}, uncompressed=${entry.uncompressedSize}, method=${entry.compressionMethod}, hasData=${entry.data !== null}`);

          if (entry.data === null && entry.compressionMethod === DEFLATE) {
            failedInflateCount++;
            console.warn(`[ZipReader] Entry "${entry.name}" FAILED to inflate!`);
          }

          entries.set(entry.name, entry);
        }
      }

      console.info(`[ZipReader] ========== ZIP READING COMPLETE ==========`);
      console.info(`[ZipReader] Total entries: ${entryCount}, Failed inflates: ${failedInflateCount}`);
      console.info(`[ZipReader] Entries map size: ${entries.size}`);

      // List all entries for debugging
      entries.forEach((entry, name) => {
        console.info(`[ZipReader] Final entry: "${name}" => hasData=${entry.data !== null}, size=${entry.uncompressedSize}`);
      });

      return entries;
    } catch (err) {
      console.error(`[ZipReader] ========== EXCEPTION ==========`);
      console.error(`[ZipReader] Error: ${(err as Error).message}`);
      console.error(`[ZipReader] Stack: ${(err as Error).stack}`);
      return entries;
    }
  }

  static async extractFile(filePath: string, targetName: string): Promise<Uint8Array | null> {
    const entries = await ZipReader.readZipFile(filePath);
    const entry = entries.get(targetName);
    return entry?.data || null;
  }

  static async extractFilesByPattern(filePath: string, pattern: RegExp): Promise<Map<string, Uint8Array>> {
    const entries = await ZipReader.readZipFile(filePath);
    const result = new Map<string, Uint8Array>();

    entries.forEach((entry, name) => {
      if (pattern.test(name) && entry.data) {
        result.set(name, entry.data);
      }
    });

    return result;
  }
}