# v0.8.1 原创像素场景与动画素材

使用 Codex 内置 image_gen 工具，以用户提供的 natural-farm-concept-v0.8.png 作为风格参考制作。三场景分开，背景不含固定动物、人物和作物；演员由游戏真实坐标驱动。source 保存生成原图，runtime 由 Godot 烘焙管线生成透明帧和场景纹理。

## 大动物独立动作图集

### cow

Use case: stylized-concept. Asset type: finished pixel game walk SPRITE ATLAS for one black and white spotted dairy cow with pink muzzle, curved modest horns and hooves. EXACT4columns4rows on square canvas,16 full-body isolated sprites. Absolutely transparent alpha. Generous transparent spacing: EACH animal fits inside central65% of its owncell, neighbors NEVERtouch. SAME animal, consistent proportions/palette/footbaseline across all16cells. ROW1 four actual walkingcycle poses facing DOWN toward viewer; ROW2 four actual walkingcycle poses facing RIGHT; ROW3 four actual walkingcycle poses facing UP away from viewer; ROW4 four actual walkingcycle poses facing LEFT. Legs must alternate visibly across the four distinct phases in every direction, full hooves visible. Rich crisp handcrafted PIXEL clusters, top-left sunlight, high detail cozy countrysidegame, shallow oblique overheadgame view, avoid blurry painting or 3D. Correct4leg anatomy, stable horn/earshape. Down/up views symmetrical, sideviews show sidebody. Four equal cellsperrow with completely clear transparent gutters around head, horns, legs, tail. No labels, no numbers, no gridlines, no floor, no shadow outsidefootprint, no scenery. Exactly16isolated, identicalsize fullanimals, ZERO extras. Original art, no logos/watermark.

### goat

Use case: stylized-concept. Asset type: finished pixel game walk SPRITE ATLAS for one cream goat with brown small horns, beard and hooves. EXACT4columns4rows on square canvas,16 full-body isolated sprites. Absolutely transparent alpha. Generous transparent spacing: EACH animal fits inside central65% of its owncell, neighbors NEVERtouch. SAME animal, consistent proportions/palette/footbaseline across all16cells. ROW1 four actual walkingcycle poses facing DOWN toward viewer; ROW2 four actual walkingcycle poses facing RIGHT; ROW3 four actual walkingcycle poses facing UP away from viewer; ROW4 four actual walkingcycle poses facing LEFT. Legs must alternate visibly across the four distinct phases in every direction, full hooves visible. Rich crisp handcrafted PIXEL clusters, top-left sunlight, high detail cozy countrysidegame, shallow oblique overheadgame view, avoid blurry painting or 3D. Correct4leg anatomy, stable horn/earshape. Down/up views symmetrical, sideviews show sidebody. Four equal cellsperrow with completely clear transparent gutters around head, horns, legs, tail. No labels, no numbers, no gridlines, no floor, no shadow outsidefootprint, no scenery. Exactly16isolated, identicalsize fullanimals, ZERO extras. Original art, no logos/watermark.

### sheep

Use case: stylized-concept. Asset type: finished pixel game walk SPRITE ATLAS for one fluffy cream sheep with black face and short dark legs. EXACT4columns4rows on square canvas,16 full-body isolated sprites. Absolutely transparent alpha. Generous transparent spacing: EACH animal fits inside central65% of its owncell, neighbors NEVERtouch. SAME animal, consistent proportions/palette/footbaseline across all16cells. ROW1 four actual walkingcycle poses facing DOWN toward viewer; ROW2 four actual walkingcycle poses facing RIGHT; ROW3 four actual walkingcycle poses facing UP away from viewer; ROW4 four actual walkingcycle poses facing LEFT. Legs must alternate visibly across the four distinct phases in every direction, full hooves visible. Rich crisp handcrafted PIXEL clusters, top-left sunlight, high detail cozy countrysidegame, shallow oblique overheadgame view, avoid blurry painting or 3D. Correct4leg anatomy, stable horn/earshape. Down/up views symmetrical, sideviews show sidebody. Four equal cellsperrow with completely clear transparent gutters around head, horns, legs, tail. No labels, no numbers, no gridlines, no floor, no shadow outsidefootprint, no scenery. Exactly16isolated, identicalsize fullanimals, ZERO extras. Original art, no logos/watermark.

### pig

Use case: stylized-concept. Asset type: finished pixel game walk SPRITE ATLAS for one pink pig with clear round snout, floppy ears and small curlytail. EXACT4columns4rows on square canvas,16 full-body isolated sprites. Absolutely transparent alpha. Generous transparent spacing: EACH animal fits inside central65% of its owncell, neighbors NEVERtouch. SAME animal, consistent proportions/palette/footbaseline across all16cells. ROW1 four actual walkingcycle poses facing DOWN toward viewer; ROW2 four actual walkingcycle poses facing RIGHT; ROW3 four actual walkingcycle poses facing UP away from viewer; ROW4 four actual walkingcycle poses facing LEFT. Legs must alternate visibly across the four distinct phases in every direction, full hooves visible. Rich crisp handcrafted PIXEL clusters, top-left sunlight, high detail cozy countrysidegame, shallow oblique overheadgame view, avoid blurry painting or 3D. Correct4leg anatomy, stable horn/earshape. Down/up views symmetrical, sideviews show sidebody. Four equal cellsperrow with completely clear transparent gutters around head, horns, legs, tail. No labels, no numbers, no gridlines, no floor, no shadow outsidefootprint, no scenery. Exactly16isolated, identicalsize fullanimals, ZERO extras. Original art, no logos/watermark.

## 其余素材制作要求

- farm：宽幅斜俯视像素乡村农田，深浅土纹、自然边缘、左侧工具小屋、林木与石块，中央为可由程序种植的裸土地；无人物、动物、文字。
- ranch：七座分立小棚舍、下方开放牧场与自然草底；无固定动物，保留真实活动空间。
- pond：独立池塘、浅深水层、木栈桥、芦苇与岩石岸，水域内不烘焙鱼。
- crops：64 类作物依 production.json 固定顺序，每种四阶段；透明底，等间距，像素边缘，脚基线一致。
- animals：11 类动物四方向步态，幼年独立图集；吃草和反馈独立帧，不添加背景。
- farmer：四方向 walk / water / sow / harvest 各动画，草帽蓝色服装，透明底。
- nature：四种草丛形态和三鱼种游动帧，保留植物本色和透明 alpha。

生成素材须通过实际透明度、完整轮廓、帧布局、各方向差异及引擎截图检查；具体帧对应关系见 runtime/manifest.json。
