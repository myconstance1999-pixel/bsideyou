import BSideCore

extension DailyAssetIssue {
    var recoveryMessage: String {
        switch self {
        case .missingLocation:
            return "找不到日常素材目录。目录可能已移动，或所在磁盘未连接；请恢复原位置后重试，或选择新位置。"
        case .accessDenied:
            return "没有权限读取日常素材。请恢复该目录的访问权限后重试，或重新选择可访问的目录。"
        case .authorizationRequired:
            return "无法恢复日常素材的访问授权。请重新选择包含画面和环境音的 assets、具体版本或安装目录。"
        case .unsupportedLayout:
            return "此位置不包含受支持的日常素材布局。请选择安装根、具体版本或 assets 文件夹。"
        case .ambiguousLayouts:
            return "所选目录包含多个可用版本，请选择其中一个具体版本文件夹。"
        case .noDailyContent:
            return "日常素材目录中没有找到受支持的日常视频。请确认素材已完整放入，再重试或选择其他目录。"
        case .readFailed:
            return "读取日常素材时发生错误。请确认目录和所在磁盘可访问后重试，或选择其他目录。"
        }
    }
}
