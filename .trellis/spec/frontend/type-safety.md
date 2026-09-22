# 边界校验

当前使用 JavaScript，运行 `npm run check:ui`；没有 TypeScript 类型检查器。IPC 接口形状以 Rust serde 结构和命令参数为准。读外部 JSON 先检查数组、对象、有限数值和缺失字段，未知额度不转成零。用户名、模型名和供应商返回字符串都视为非可信展示内容。
