# AGENTS.md

## Project Overview
这是一个 iOS / Swift 项目，用于……

## Code Style
- UI 文案使用中文
- 不引入新依赖，除非用户确认
- 如果 GitHub/npm 上有成熟的开源方案，直接复用，不要自己实现。谨慎使用过于冗余、过大、安全性存疑、长时间无维护无更新且功能不完善的包；如必须使用，请告知风险。

## Important Files
- `milkTCompendium/`：主要源码
- `README.md`：项目说明
- `docs/`：文档、修改记录等
- `docs/TODO.md`：项目统一待做事项记录

## Working Rules
- 分析 bug 的时候，要从第一性原理出发，不要搞兜底实现，不要掩盖主流程的错误。
- 修改前先查看相关文件
- 不要重置用户未提交的改动
- 新增、发现或暂缓的项目待做事项统一记录到 `docs/TODO.md`
- 完成后说明改了什么、是否验证通过
