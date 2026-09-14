export interface NoteSummary {
  id: string;
  type: string;
  title: string;
  tags: string[];
  pinned: boolean;
  version: number;
  groupId: string | null;
  /** 密码卡片是否加密存储（false = 明文卡片） */
  enc: boolean;
  deletedAt: string | null;
  createdAt: string;
  updatedAt: string;
  excerpt: string;
  /** 仅卡片类型返回：加密卡为密文，明文卡为 JSON */
  content?: string;
}

export interface Note {
  id: string;
  type: string;
  title: string;
  content: string;
  plainText: string;
  tags: string[];
  pinned: boolean;
  version: number;
  groupId: string | null;
  /** 密码卡片是否加密存储 */
  enc: boolean;
  deletedAt: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface Group {
  id: string;
  name: string;
  parentId: string | null;
  createdAt?: string;
  count?: number;
}

export interface AuthStatus {
  setupNeeded: boolean;
  authenticated: boolean;
  username: string | null;
}

export interface Stats {
  noteCount: number;
  trashCount: number;
  groupCount: number;
  attachmentCount: number;
  attachmentBytes: number;
  tagCount: number;
  lastAutoBackup?: string;
}

export interface AppSettings {
  theme: string;
  trashCleanDays: number;
  cardLock: string;
  cardEncrypt: string;
}
