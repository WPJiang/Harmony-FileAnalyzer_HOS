import { ModalityType } from './DataBlock';
import { FileMetadata, MetadataValue } from './DatabaseModels';

export class SemanticBlock {
  blockId: string = ''
  textDescription: string = ''
  keywords: string[] = []
  semanticVector: number[] = []
  modality: ModalityType = ModalityType.TEXT
  originalMetadata: FileMetadata = {} as FileMetadata

  constructor() {
  }

  setBlockId(id: string): void {
    this.blockId = id;
  }

  setTextDescription(desc: string): void {
    this.textDescription = desc;
  }

  setKeywords(kw: string[]): void {
    this.keywords = kw;
  }

  setSemanticVector(vec: number[]): void {
    this.semanticVector = vec;
  }

  setModality(mod: ModalityType): void {
    this.modality = mod;
  }

  setOriginalMetadata(meta: FileMetadata): void {
    this.originalMetadata = meta;
  }

  toMap(): Record<string, MetadataValue> {
    const result: Record<string, MetadataValue> = {} as Record<string, MetadataValue>;
    result['blockId'] = this.blockId;
    result['textDescription'] = this.textDescription;
    result['modality'] = this.modality;
    return result;
  }

  static fromMap(map: Record<string, MetadataValue>): SemanticBlock {
    const block = new SemanticBlock();
    block.blockId = map['blockId'] as string || '';
    block.textDescription = map['textDescription'] as string || '';
    block.keywords = map['keywords'] as string[] || [];
    // Handle semanticVector conversion
    const vec = map['semanticVector'];
    if (vec && Array.isArray(vec)) {
      block.semanticVector = vec.map(v => typeof v === 'number' ? v : parseFloat(v as string));
    } else {
      block.semanticVector = [];
    }
    block.modality = map['modality'] as ModalityType || ModalityType.TEXT;
    return block;
  }
}
