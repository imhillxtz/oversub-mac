# Thông báo bản quyền của phần mềm bên thứ ba · Third-party notices

OverSub dùng lại mã hoặc thuật toán sau trong Màn hình chơi game. Bản cài kèm tệp này trong `OverSub.app/Contents/Resources`.

OverSub reuses the following code or algorithms in the game screen. The app bundle ships this file in `OverSub.app/Contents/Resources`.

## AMD FidelityFX Super Resolution 1 (FSR 1: EASU, RCAS)

Chuyển sang Metal từ `ffx_fsr1.h` (https://github.com/GPUOpen-Effects/FidelityFX-FSR). Ported to Metal from `ffx_fsr1.h`.

```
Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## Anime4K

Trọng số mạng và cấu trúc lớp lấy từ `Anime4K_3DGraphics_AA_Upscale_x2_US.glsl` và `Anime4K_Upscale_CNN_x2_S.glsl`
(https://github.com/bloc97/Anime4K), chuyển tự động sang Metal. Network weights and layer layout from those two files,
converted to Metal.

```
MIT License

Copyright (c) 2019 bloc97

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## FXAA

Bộ khử răng cưa viết lại theo thuật toán FXAA 3.11 (bản Quality) của Timothy Lottes, NVIDIA. Anti-aliasing rewritten after
Timothy Lottes' FXAA 3.11 (Quality) algorithm, NVIDIA.
