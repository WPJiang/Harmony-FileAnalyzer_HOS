import { FileRecord, FileStatus } from '../models/Index';

export interface FileItem {
  id: number;
  name: string;
  path: string;
  size: number;
  type: string;
  modifiedTime: string;
  status: FileStatus;
  category: string;
  confidence: number;
}

export class FileViewModel {
  files: FileItem[] = [];
  selectedFiles: Set<number> = new Set();
  currentDirectory: string = '';
  viewMode: 'list' | 'grid' = 'list';
  sortBy: 'name' | 'date' | 'size' | 'type' = 'name';
  sortOrder: 'asc' | 'desc' = 'asc';
  searchQuery: string = '';
  isLoading: boolean = false;

  setFiles(files: FileItem[]): void {
    this.files = files;
  }

  addFile(file: FileItem): void {
    this.files.push(file);
  }

  removeFile(id: number): void {
    this.files = this.files.filter(f => f.id !== id);
    this.selectedFiles.delete(id);
  }

  toggleSelection(id: number): void {
    if (this.selectedFiles.has(id)) {
      this.selectedFiles.delete(id);
    } else {
      this.selectedFiles.add(id);
    }
  }

  selectAll(): void {
    this.files.forEach(f => this.selectedFiles.add(f.id));
  }

  clearSelection(): void {
    this.selectedFiles.clear();
  }

  setViewMode(mode: 'list' | 'grid'): void {
    this.viewMode = mode;
  }

  setSortBy(sortBy: 'name' | 'date' | 'size' | 'type'): void {
    if (this.sortBy === sortBy) {
      this.sortOrder = this.sortOrder === 'asc' ? 'desc' : 'asc';
    } else {
      this.sortBy = sortBy;
      this.sortOrder = 'asc';
    }
  }

  setSearchQuery(query: string): void {
    this.searchQuery = query;
  }

  getFilteredFiles(): FileItem[] {
    let filtered = this.files;

    if (this.searchQuery) {
      const query = this.searchQuery.toLowerCase();
      filtered = filtered.filter(f =>
        f.name.toLowerCase().includes(query) ||
        f.path.toLowerCase().includes(query)
      );
    }

    filtered.sort((a, b) => {
      let comparison = 0;
      switch (this.sortBy) {
        case 'name':
          comparison = a.name.localeCompare(b.name);
          break;
        case 'date':
          comparison = a.modifiedTime.localeCompare(b.modifiedTime);
          break;
        case 'size':
          comparison = a.size - b.size;
          break;
        case 'type':
          comparison = a.type.localeCompare(b.type);
          break;
      }
      return this.sortOrder === 'desc' ? -comparison : comparison;
    });

    return filtered;
  }

  getFilesByCategory(): Map<string, FileItem[]> {
    const categories = new Map<string, FileItem[]>();

    for (const file of this.files) {
      const category = file.category || '未分类';
      if (!categories.has(category)) {
        categories.set(category, []);
      }
      categories.get(category)!.push(file);
    }

    return categories;
  }

  formatFileSize(bytes: number): string {
    if (bytes === 0) return '0 B';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
  }

  getFileIcon(type: string): Resource {
    const iconMap: Map<string, Resource> = new Map();
    iconMap.set('pdf', $r('app.media.startIcon'));
    iconMap.set('doc', $r('app.media.startIcon'));
    iconMap.set('docx', $r('app.media.startIcon'));
    iconMap.set('xls', $r('app.media.startIcon'));
    iconMap.set('xlsx', $r('app.media.startIcon'));
    iconMap.set('ppt', $r('app.media.startIcon'));
    iconMap.set('pptx', $r('app.media.startIcon'));
    iconMap.set('jpg', $r('app.media.startIcon'));
    iconMap.set('jpeg', $r('app.media.startIcon'));
    iconMap.set('png', $r('app.media.startIcon'));
    iconMap.set('gif', $r('app.media.startIcon'));
    iconMap.set('txt', $r('app.media.startIcon'));
    iconMap.set('md', $r('app.media.startIcon'));

    const icon = iconMap.get(type);
    return icon !== undefined ? icon : $r('app.media.startIcon');
  }

  getStatusText(status: FileStatus): string {
    switch (status) {
      case FileStatus.PENDING:
        return '待分析';
      case FileStatus.PRELIMINARY:
        return '初步分析';
      case FileStatus.DEEP:
        return '深入分析';
      default:
        return '未知';
    }
  }

  getStatusColor(status: FileStatus): Resource {
    switch (status) {
      case FileStatus.PENDING:
        return $r('app.color.status_pending');
      case FileStatus.PRELIMINARY:
        return $r('app.color.status_preliminary');
      case FileStatus.DEEP:
        return $r('app.color.status_deep');
      default:
        return $r('app.color.status_default');
    }
  }
}
