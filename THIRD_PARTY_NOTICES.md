# Third-party notices

## PaddleOCR PP-OCRv5 Latin Mobile recognition model

Flowboard X distributes the official
`PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx` model and its inference
configuration at upstream revision
`89d3a50e2c27e2e7cceeab0e944c25c807d5db4f`.

- Copyright: PaddlePaddle Authors
- License: Apache License 2.0
- Source: https://huggingface.co/PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx
- Model SHA-256:
  `7888113072263cb471b93f66dd5e2ad70548dc526fa1ace760d0d973dd121498`
- Full license:
  `android/app/src/main/assets/handwriting/PADDLEOCR_APACHE_2_LICENSE.txt`

## Microsoft ONNX Runtime Android

Flowboard X uses ONNX Runtime Android 1.23.2 to execute the bundled model
locally.

- Copyright: Microsoft Corporation
- License: MIT
- Source: https://github.com/microsoft/onnxruntime
- Full license:
  `android/app/src/main/assets/handwriting/ONNXRUNTIME_MIT_LICENSE.txt`

## Google ML Kit bundled Latin Text Recognition

The statically packaged ML Kit Latin image-recognition model remains a
defensive fallback if the primary ONNX session cannot be initialized on a
device. It is not the Play Services variant and performs no model download.
Use of ML Kit is governed by Google's ML Kit terms.
