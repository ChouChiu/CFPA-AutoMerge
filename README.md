# CFPA-AutoMerge

每 6 小时把 [CFPA 简体中文模组汉化包](https://github.com/CFPAOrg/Minecraft-Mod-Language-Package) 所有未合并的 PR 合并到 main 上，用上游自带的 Packer 打包并计算 MD5，发布到 [`automerge`](https://github.com/ChouChiu/CFPA-AutoMerge/releases/tag/automerge) Release

用于提前体验尚未合并的翻译，[I18nAutoUpdateMod](https://github.com/ChouChiu/I18nAutoUpdateMod) 开启 `betaPack` 后会优先下载这里的包

## 合并规则

- 排除 draft PR，按 PR 编号从新到旧依次合并
- 与已合并内容冲突的 PR 直接跳过
- 引入无法解析的语言 JSON，或让 packer-policy 引用不存在路径的 PR 撤回并跳过
- Packer 只从干净的 main 构建，PR 中的代码改动不会被执行
- 某个版本打包失败时，该版本回退为上游 autobuild 的文件
- 每次合并与跳过的 PR 列表写在 Release 说明里

## 文件

文件名与上游 [`autobuild`](https://github.com/CFPAOrg/Minecraft-Mod-Language-Package/releases/tag/autobuild) 完全一致，可以直接替换下载地址

- 资源包：`Minecraft-Mod-Language-Modpack-<版本>.zip`，例如 `Minecraft-Mod-Language-Modpack-1-20-Fabric.zip`，1.12.2 为 `Minecraft-Mod-Language-Modpack.zip`
- 校验：`<版本>.md5`，例如 `1.20-fabric.md5`，内容为大写 MD5，无换行
- 1.10.2 上游已不再打包，原样复制自 autobuild

下载地址前缀：

```
https://github.com/ChouChiu/CFPA-AutoMerge/releases/download/automerge/
```

## 本地运行

依赖 `git`、`gh`（已登录）、`dotnet` 10 与 `python3`

```shell
LIMIT=5 ./automerge.sh
```

`LIMIT` 只合并最新的若干个 PR，省略则合并全部，产物输出到 `dist/`

## 协议

脚本以 MIT 协议开源，资源包内的翻译内容遵循上游的 [CC BY-NC-SA 4.0](https://github.com/CFPAOrg/Minecraft-Mod-Language-Package/blob/main/LICENSE) 协议
