# v0.7 像素素材与实现说明

日期：2026-10-01。使用内置 imagegen 工具生成原创光栅图集，参考星露谷物语的乡村像素配色、轮廓和角色比例。用户提供的灰机Wiki汇总页直接访问返回403；检索可读取部分作物子页面，用于核对品种外观与分类。玩法生长时间、售价、产量不取自Wiki，仍沿用已确认的数值文档。

参考：[农作物](https://xinglugu.huijiwiki.com/wiki/%E5%86%9C%E4%BD%9C%E7%89%A9)、[动物](https://xinglugu.huijiwiki.com/wiki/%E5%8A%A8%E7%89%A9)、[蓝莓](https://xinglugu.huijiwiki.com/wiki/%E8%93%9D%E8%8E%93)、[上古水果](https://xinglugu.huijiwiki.com/wiki/%E4%B8%8A%E5%8F%A4%E6%B0%B4%E6%9E%9C)。

## 文件与映射

| 文件 | 网格 | 内容 |
| --- | --- | --- |
| assets/pixel/crops-atlas-v0.7.png | 8×8 | 53种作物/种包，加野生植物图标 |
| assets/pixel/animals-atlas-v0.7.png | 4×4 | 11动物、幼鸡、3鱼与干草 |
| assets/pixel/farmer-atlas-v0.7.png | 4×4 | 向右/向左行走、浇水、收割，各4帧 |
| assets/pixel/products-atlas-v0.7.png | 4×4 | 米、冬季野果/根/花、禽蛋、羊毛、奶、松露与牧草物品 |

完整格位由 scripts/pixel_assets.gd 的固定ID数组定义。源图保持真正RGBA透明，尺寸1254×1254；scripts/bake_pixel_assets.gd 在构建时最近邻转换并保存至 assets/pixel/runtime/，作物图集256×256，其余128×128，每格32×32。试玩PCK只包含小图集，原始大图仍纳入Git，不在游玩时解码或上传。地面、泥土、木框、建筑和水岸继续由可缓存的像素绘制程序构成。

## 提示词

每份图集的完整生成提示词保存在 assets/pixel/generation-prompts.md，试玩包同时提供 docs/art-generation-prompts-v0.7.md。所有调用使用内置工具的 transparent_background=true，无CLI/API密钥依赖。素材经过布局与Alpha检查，并在实际界面复核格位、缩放和可辨认性。
