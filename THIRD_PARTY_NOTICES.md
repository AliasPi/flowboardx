# Third-party notices

## PaddleOCR PP-OCRv6 Small recognition model

Flowboard X distributes the official
`PaddlePaddle/PP-OCRv6_small_rec_onnx` model and its inference
configuration at upstream revision
`b8f84f0b80c529de40b4fbb3544b84fa7233a513`.

- Copyright: PaddlePaddle Authors
- License: Apache License 2.0
- Source: https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx
- Model SHA-256:
  `5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634`
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
defensive fallback if the primary ONNX session cannot be initialized and an
independent corroboration engine for uncertain candidates. It is not the Play
Services variant and performs no model download. Use of ML Kit is governed by
Google's ML Kit terms.
