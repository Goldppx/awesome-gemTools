# 第三方许可

本目录的应用代码采用 Apache-2.0。vendor 内的上游代码和许可保持原样，不属于本工具的重新许可范围。

| 组件 | 版本 | 许可文件 |
| --- | --- | --- |
| PDF.js / pdfjs-dist | 3.11.174 | [Apache-2.0](vendor/LICENSE-pdfjs.txt)；Copyright 2023 Mozilla Foundation |
| pdf-lib | 1.17.1 | [MIT](vendor/LICENSE-pdf-lib.md)；Copyright 2019 Andrew Dillon |
| @pdf-lib/standard-fonts（随 pdf-lib 打包） | 1.0.0 | [MIT](vendor/LICENSE-standard-fonts.md) |
| @pdf-lib/upng（随 pdf-lib 打包） | 1.0.1 | [MIT](vendor/LICENSE-upng.txt) |
| pako（随 pdf-lib 打包） | 1.0.10 / 1.0.11 | [MIT](vendor/LICENSE-pako.txt) |
| tslib（随 pdf-lib 打包） | 1.11.1 | [Apache-2.0](vendor/LICENSE-tslib.txt)；Microsoft Corporation，另见 bundle 内的原始版权注释 |

版本依据：[pdf-lib v1.17.1 的锁文件](https://github.com/Hopding/pdf-lib/blob/v1.17.1/yarn.lock)。

PDF.js 文件取自 https://unpkg.com/pdfjs-dist@3.11.174/build/；pdf-lib 取自 https://unpkg.com/pdf-lib@1.17.1/dist/pdf-lib.min.js。再分发时保留这些许可文件和库文件内部已有的版权及许可注释。
