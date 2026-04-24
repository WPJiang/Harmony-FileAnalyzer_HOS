export class SemanticCategory {
  name: string = '';
  description: string = '';
  keywords: string[] = [];
  centerVector: number[] = [];

  constructor() {
  }

  setName(name: string): void {
    this.name = name;
  }

  setDescription(description: string): void {
    this.description = description;
  }

  setKeywords(keywords: string[]): void {
    this.keywords = keywords;
  }

  setCenterVector(centerVector: number[]): void {
    this.centerVector = centerVector;
  }
}

export class ClusterResult {
  blockId: string = '';
  clusterId: number = 0;
  clusterName: string = '';
  confidence: number = 0;
  distanceToCenter: number = 0;

  constructor() {
  }
}

export class SimilarityResult {
  queryId: string = '';
  targetId: string = '';
  vectorSimilarity: number = 0;
  bm25Score: number = 0;
  keywordSimilarity: number = 0;
  timeSimilarity: number = 0;
  locationSimilarity: number = 0;
  fusedScore: number = 0;

  constructor() {
  }
}

export class QueryResult {
  blockIds: string[] = [];
  score: number = 0;
  matchedKeywords: string[] = [];
  matchType: string = '';

  constructor() {
  }
}
