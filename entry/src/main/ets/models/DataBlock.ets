import { FileMetadata, MetadataValue } from './DatabaseModels';

export enum ModalityType {
  TEXT = 'text',
  IMAGE = 'image',
  TABLE = 'table',
  AUDIO = 'audio',
  VIDEO = 'video',
  PDF = 'pdf'
}

export class DataBlock {
  blockId: string = ''
  modality: ModalityType = ModalityType.TEXT
  content: string = ''
  metadata: FileMetadata = {} as FileMetadata
  textContent: string = ''
  filePath: string = ''  // 原始文件路径
  addr: string = ''      // 数据块文件路径（cache目录下），与Python项目保持一致
  pageNumber: number = 1
  position: FileMetadata = {} as FileMetadata

  constructor() {
  }

  setBlockId(id: string): void {
    this.blockId = id;
  }

  setModality(mod: ModalityType): void {
    this.modality = mod;
  }

  setContent(c: string): void {
    this.content = c;
  }

  setMetadata(meta: FileMetadata): void {
    this.metadata = meta;
  }

  setTextContent(text: string): void {
    this.textContent = text;
  }

  setFilePath(path: string): void {
    this.filePath = path;
  }

  setAddr(addr: string): void {
    this.addr = addr;
  }

  setPageNumber(num: number): void {
    this.pageNumber = num;
  }

  setPosition(pos: FileMetadata): void {
    this.position = pos;
  }

  toMap(): Record<string, MetadataValue> {
    const result: Record<string, MetadataValue> = {} as Record<string, MetadataValue>;
    result['blockId'] = this.blockId;
    result['modality'] = this.modality;
    result['content'] = this.content;
    result['textContent'] = this.textContent;
    result['filePath'] = this.filePath;
    result['addr'] = this.addr;
    result['pageNumber'] = this.pageNumber;
    return result;
  }

  static fromMap(map: Record<string, MetadataValue>): DataBlock {
    const block = new DataBlock();
    block.blockId = map['blockId'] as string || '';
    block.modality = map['modality'] as ModalityType || ModalityType.TEXT;
    block.content = map['content'] as string || '';
    block.textContent = map['textContent'] as string || '';
    block.filePath = map['filePath'] as string || '';
    block.addr = map['addr'] as string || '';
    block.pageNumber = map['pageNumber'] as number || 1;
    return block;
  }
}
