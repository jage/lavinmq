
### idle: per run

| round | variant | coll/min | p50 ms | p90 ms | max ms | GC ms/min | RSS peak MB | RSS end MB | max at (s) | finalizers/s |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | main | 19.0 | 208.7 | 239.3 | 262.7 | 3986.9 | 492 | 473 | 35.7 | File 4.7, TCPSocket 2.3, OpenSSL::Digest 2.3 |
| 1 | combo16k | 20.0 | 49.5 | 59.9 | 179.5 | 1060.3 | 495 | 469 | 0.2 | TCPSocket 5.1, File 4.8 |
| 1 | combo32k | 19.5 | 46.9 | 61.5 | 67.8 | 939.0 | 494 | 469 | 1.1 | TCPSocket 5.7, File 4.8 |
| 2 | main | 18.5 | 217.2 | 249.9 | 261.7 | 4049.5 | 491 | 469 | 23.4 | File 4.7, TCPSocket 1.2, OpenSSL::Digest 1.2 |
| 2 | combo16k | 19.5 | 52.2 | 67.5 | 227.0 | 1128.4 | 495 | 474 | 1.1 | TCPSocket 7.7, File 4.8 |
| 2 | combo32k | 19.5 | 51.5 | 60.5 | 65.5 | 1013.0 | 493 | 467 | 89.6 | File 4.8, TCPSocket 1.3 |
| 3 | main | 19.0 | 190.0 | 217.4 | 266.1 | 3586.9 | 493 | 473 | 6.9 | File 4.7, TCPSocket 2.4, OpenSSL::Digest 2.4 |
| 3 | combo16k | 19.5 | 50.7 | 61.4 | 166.7 | 1063.3 | 495 | 467 | 0.6 | File 4.8, TCPSocket 1.3 |
| 3 | combo32k | 20.0 | 55.7 | 65.5 | 79.1 | 1138.5 | 495 | 473 | 52.4 | File 4.8, TCPSocket 4.7 |
| 4 | main | 19.0 | 196.5 | 228.8 | 247.7 | 3765.5 | 491 | 469 | 6.7 | File 4.7, TCPSocket 2.9, OpenSSL::Digest 2.9 |
| 4 | combo16k | 19.5 | 49.8 | 64.3 | 218.0 | 1085.2 | 496 | 469 | 1.2 | TCPSocket 6.8, File 4.8 |
| 4 | combo32k | 19.5 | 53.4 | 61.1 | 68.1 | 1034.7 | 494 | 468 | 114.0 | File 4.8, TCPSocket 1.3 |
| 5 | main | 19.0 | 197.7 | 238.2 | 250.6 | 3802.5 | 491 | 468 | 80.8 | File 4.7, TCPSocket 2.5, OpenSSL::Digest 2.5 |
| 5 | combo16k | 19.5 | 47.2 | 56.8 | 179.2 | 1001.1 | 493 | 469 | 1.0 | TCPSocket 9.2, File 4.8 |
| 5 | combo32k | 19.5 | 48.3 | 52.6 | 353.6 | 1089.0 | 495 | 469 | 56.5 | TCPSocket 7.1, File 4.8 |

### idle: medians (n=5 per variant) and main/combo ratio

| metric | main | combo16k | combo32k | main/combo16k | main/combo32k |
|---|---|---|---|---|---|
| coll/min | 19.0 | 19.5 | 19.5 | 0.97x | 0.97x |
| p50 ms | 197.7 | 49.8 | 51.5 | 3.97x | 3.84x |
| p90 ms | 238.2 | 61.4 | 61.1 | 3.88x | 3.90x |
| max ms | 261.7 | 179.5 | 68.1 | 1.46x | 3.84x |
| GC ms/min | 3802.5 | 1063.3 | 1034.7 | 3.58x | 3.67x |
| RSS peak MB | 491.0 | 495.0 | 494.0 | 0.99x | 0.99x |
| RSS end MB | 469.0 | 469.0 | 469.0 | 1.00x | 1.00x |
| finalizers/s File | 4.7 | 4.8 | 4.8 | | |
| finalizers/s OpenSSL::Digest | 2.4 | 0.0 | 0.0 | | |
| finalizers/s TCPSocket | 2.4 | 6.8 | 4.7 | | |

### churn: per run

| round | variant | coll/min | p50 ms | p90 ms | max ms | GC ms/min | RSS peak MB | RSS end MB | max at (s) | finalizers/s |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | main | 4.7 | 239.4 | 313.0 | 332.7 | 1129.6 | 630 | 580 | 224.2 | TCPSocket 201.2, OpenSSL::Digest 201.2, File 4.8 |
| 1 | combo16k | 2.5 | 68.8 | 198.1 | 198.1 | 204.1 | 633 | 577 | 10.7 | TCPSocket 203.1, File 4.8 |
| 1 | combo32k | 2.5 | 73.3 | 92.4 | 92.4 | 183.5 | 631 | 575 | 154.7 | TCPSocket 200.4, File 4.8 |
| 2 | main | 4.5 | 220.5 | 272.6 | 309.1 | 1021.6 | 628 | 584 | 220.4 | TCPSocket 201.1, OpenSSL::Digest 201.1, File 4.8 |
| 2 | combo16k | 2.5 | 64.3 | 220.3 | 220.3 | 191.6 | 631 | 576 | 10.7 | TCPSocket 202.4, File 4.8 |
| 2 | combo32k | 2.5 | 67.5 | 78.5 | 78.5 | 163.5 | 647 | 591 | 199.6 | TCPSocket 204.1, File 4.8 |
| 3 | main | 4.5 | 237.7 | 310.2 | 315.2 | 1073.4 | 630 | 587 | 196.9 | TCPSocket 200.4, OpenSSL::Digest 200.4, File 4.8 |
| 3 | combo16k | 2.5 | 73.9 | 199.7 | 199.7 | 207.2 | 633 | 577 | 10.7 | TCPSocket 203.1, File 4.8 |
| 3 | combo32k | 2.5 | 66.5 | 73.5 | 73.5 | 161.2 | 632 | 576 | 36.1 | TCPSocket 200.4, File 4.8 |
| 4 | main | 4.8 | 216.8 | 275.4 | 278.8 | 1088.5 | 631 | 581 | 112.4 | TCPSocket 201.1, OpenSSL::Digest 201.1, File 4.8 |
| 4 | combo16k | 2.5 | 72.1 | 199.6 | 199.6 | 209.0 | 647 | 591 | 10.3 | TCPSocket 202.1, File 4.8 |
| 4 | combo32k | 2.5 | 75.7 | 101.1 | 101.1 | 188.6 | 631 | 575 | 131.8 | TCPSocket 201.0, File 4.8 |
| 5 | main | 4.8 | 238.3 | 271.9 | 286.3 | 1119.7 | 629 | 576 | 28.3 | TCPSocket 200.2, OpenSSL::Digest 200.2, File 4.8 |
| 5 | combo16k | 2.5 | 81.1 | 224.9 | 224.9 | 225.7 | 632 | 576 | 10.7 | TCPSocket 203.7, File 4.8 |
| 5 | combo32k | 2.5 | 68.8 | 110.9 | 110.9 | 186.8 | 647 | 599 | 83.6 | TCPSocket 204.5, File 4.8 |

### churn: medians (n=5 per variant) and main/combo ratio

| metric | main | combo16k | combo32k | main/combo16k | main/combo32k |
|---|---|---|---|---|---|
| coll/min | 4.7 | 2.5 | 2.5 | 1.90x | 1.90x |
| p50 ms | 237.7 | 72.1 | 68.8 | 3.30x | 3.45x |
| p90 ms | 275.4 | 199.7 | 92.4 | 1.38x | 2.98x |
| max ms | 309.1 | 199.7 | 92.4 | 1.55x | 3.35x |
| GC ms/min | 1088.5 | 207.2 | 183.5 | 5.25x | 5.93x |
| RSS peak MB | 630.0 | 633.0 | 632.0 | 1.00x | 1.00x |
| RSS end MB | 581.0 | 577.0 | 576.0 | 1.01x | 1.01x |
| finalizers/s File | 4.8 | 4.8 | 4.8 | | |
| finalizers/s OpenSSL::Digest | 201.1 | 0.0 | 0.0 | | |
| finalizers/s TCPSocket | 201.1 | 203.1 | 201.0 | | |
