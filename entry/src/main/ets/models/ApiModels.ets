/**
 * API Models - Request/Response interfaces for FileAnalyzer backend API
 */

import { FileMetadata } from './DatabaseModels';

// ============ Request Models ============

export interface ScanRequest {
  directory_path: string;
  recursive: boolean;
}

export interface ParseRequest {
  file_path: string;
  parsing_mode?: number;
}

export interface AnalyzeRequest {
  file_path: string;
  parsing_mode?: number;
}

export interface ClassifyRequest {
  text: string;
  method?: string;
}

export interface SearchRequest {
  query: string;
  top_k?: number;
}

export interface OcrRequest {
  image_path: string;
}

export interface EmbedRequest {
  text: string;
}

export interface LlmDescribeRequest {
  text: string;
  prompt?: string;
}

// New Request Models for extended API

export interface SemanticRepresentRequest {
  file_id: number;
}

export interface ClassifyFileRequest {
  file_id: number;
  category_system_name?: string;
}

export interface ImageMetadataRequest {
  file_id?: number;
  file_path?: string;
}

export interface ImageCaptionRequest {
  file_id?: number;
  file_path?: string;
}

// ============ Response Models ============

export interface HealthResponse {
  status: string;
  models_loaded: boolean;
  file_count: number;
}

export interface ScanResponse {
  files: FileInfo[];
  total: number;
}

export interface FileInfo {
  path: string;
  name: string;
  extension: string;
}

export interface ParseResponse {
  blocks: DataBlockInfo[];
  count: number;
}

export interface DataBlockInfo {
  block_id: string;
  modality: string;
  content: string;
  text_content: string;
  page_number: number;
  metadata: Record<string, Object>;
}

export interface AnalyzeResponse {
  file_id: number;
  blocks_count: number;
  semantic_blocks_count: number;
  categories: CategoryResult[];
}

export interface CategoryResult {
  category: string;
  confidence: number;
}

export interface ClassifyResponse {
  categories: CategoryResult[];
}

export interface SearchResponse {
  results: FileSearchResult[];
  semantic_blocks: SemanticBlockResult[];
  query: string;
  total_files: number;
  total_blocks: number;
}

export interface FileSearchResult {
  file_id: number;
  file_path: string;
  file_name: string;
  similarity_score: number;
  matched_blocks: MatchedBlock[];
}

export interface MatchedBlock {
  semantic_block_id: string;
  file_id: number;
  text_description: string;
  keywords: string[];
  similarity_score: number;
}

export interface SemanticBlockResult {
  semantic_block_id: string;
  file_id: number;
  text_description: string;
  keywords: string[];
  similarity_score: number;
}

export interface OcrResponse {
  text: string;
  confidence: number;
}

export interface EmbedResponse {
  vector: number[];
  dimension: number;
}

export interface LlmDescribeResponse {
  description: string;
}

export interface FileListResponse {
  files: FileRecordInfo[];
  count: number;
}

export interface FileRecordInfo {
  id: number;
  file_path: string;
  file_name: string;
  file_size: number;
  file_type: string;
  modified_time: string | null;
  created_time: string | null;
  analysis_status: number;
  semantic_categories: CategoryResult[];
  directory_path: string;
  added_time: string | null;
  semantic_filename: string | null;
  metadata: Record<string, Object> | null;
}

export interface FileDetailResponse {
  file: FileRecordInfo;
  data_blocks: DataBlockDetail[];
  semantic_blocks: SemanticBlockDetail[];
  classification_results: ClassificationDetail[];
}

export interface DataBlockDetail {
  id: number;
  block_id: string;
  modality: string;
  addr: string;
  page_number: number;
  metadata: Record<string, Object>;
}

export interface SemanticBlockDetail {
  id: number;
  semantic_block_id: string;
  data_block_ids: number[];
  file_id: number;
  text_description: string;
  keywords: string[];
  semantic_filename: string | null;
  metadata: Record<string, Object>;
  created_time: string | null;
}

export interface ClassificationDetail {
  id: number;
  semantic_block_id: string;
  category_name: string;
  category_system_name: string;
  confidence: number;
  all_scores: Record<string, number>;
  created_time: string | null;
}

export interface CategoriesResponse {
  category_systems: Record<string, CategorySystemItem[]>;
  total_categories: number;
}

export interface CategorySystemItem {
  id: number;
  category_name: string;
  description: string;
  keywords: string[];
  category_source: string;
  created_time: string | null;
}

// ============ API Error ============

export interface ApiError {
  detail: string;
}

// ============ New Response Models for Extended API ============

export interface SemanticRepresentResponse {
  file_id: number;
  semantic_blocks_count: number;
  success: boolean;
  message?: string;
}

export interface ClassifyFileResponse {
  file_id: number;
  categories: CategoryResult[];
  primary_category: string;
  confidence: number;
  success: boolean;
  message?: string;
}

export interface ClearHistoryResponse {
  deleted_files: number;
  deleted_blocks: number;
  success: boolean;
  message?: string;
}

export interface ClearClassificationResponse {
  success: boolean;
  message?: string;
}

export interface GpsCoordinates {
  lat: number;
  lon: number;
}

export interface ImageDimensions {
  width: number;
  height: number;
}

export interface ImageMetadataResponse {
  file_id: number | null;
  capture_time?: string;
  location?: string;
  gps_coordinates?: GpsCoordinates;
  dimensions?: ImageDimensions;
  success: boolean;
}

export interface ImageCaptionResponse {
  file_id: number | null;
  caption?: string;
  tags?: string[];
  success: boolean;
}
