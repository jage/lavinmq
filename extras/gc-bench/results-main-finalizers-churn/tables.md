| run | gcs/min | gcs/min 2nd half | p50 | p90 | max ms | GC ms/min | GC ms/min 2nd half | RSS med / peak MB | alloc MiB/s | finalizer registrations/s | socket unreg/s | trigger (whole window) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1/main | 4.5 | 2.5 | 247.1 | 327.1 | 331.7 | 1096 | 709.3 | 624 / 631 | 4.28 | TCPSocket 200.8, OpenSSL::Digest 200.8, File 4.8 | - | grow_table 13, collect_or_expand 5 |
| r2/main | 4.5 | 2.5 | 231.6 | 262.3 | 267.8 | 1043.9 | 590.9 | 624 / 632 | 4.28 | TCPSocket 200.7, OpenSSL::Digest 200.7, File 4.8 | - | grow_table 13, collect_or_expand 5 |
| r3/main | 5 | 2.5 | 235.9 | 290.5 | 333.3 | 1207.7 | 650.3 | 623 / 632 | 4.28 | TCPSocket 201, OpenSSL::Digest 201, File 4.8 | - | grow_table 15, collect_or_expand 5 |
| r4/main | 4.75 | 2.5 | 246.5 | 291.1 | 294.8 | 1150.6 | 612.5 | 621 / 631 | 4.28 | TCPSocket 200.8, OpenSSL::Digest 200.8, File 4.8 | - | grow_table 14, collect_or_expand 5 |
| r5/main | 4.5 | 2.5 | 223.1 | 276.4 | 308.6 | 988.6 | 618.2 | 622 / 630 | 4.28 | TCPSocket 201.2, OpenSSL::Digest 201.2, File 4.8 | - | grow_table 13, collect_or_expand 5 |
| r1/main-socket | 6.75 | 7 | 224.3 | 268.1 | 294.9 | 1577.4 | 1639.8 | 556 / 562 | 4.28 | TCPSocket 200.9, OpenSSL::Digest 200.9, File 4.8 | 200.9 | grow_table 27 |
| r2/main-socket | 6.75 | 7 | 239.2 | 275.2 | 291 | 1637.9 | 1692.2 | 556 / 562 | 4.28 | TCPSocket 200.9, OpenSSL::Digest 200.9, File 4.8 | 200.9 | grow_table 27 |
| r3/main-socket | 6.75 | 7 | 231.8 | 262.6 | 301.1 | 1596.1 | 1646.3 | 557 / 563 | 4.28 | TCPSocket 200.9, OpenSSL::Digest 200.9, File 4.8 | 200.9 | grow_table 27 |
| r4/main-socket | 6.75 | 7 | 221.4 | 250.2 | 359 | 1538.3 | 1540.8 | 555 / 560 | 4.28 | TCPSocket 200.8, OpenSSL::Digest 200.8, File 4.8 | 200.8 | grow_table 27 |
| r5/main-socket | 6.75 | 7 | 243.5 | 282.2 | 296.7 | 1590.6 | 1670 | 555 / 561 | 4.27 | TCPSocket 200.6, OpenSSL::Digest 200.6, File 4.8 | 200.6 | grow_table 27 |
| r1/digest | 3.25 | 2.5 | 252.6 | 309.9 | 318.5 | 830.2 | 674.4 | 623 / 640 | 4.26 | TCPSocket 200.9, File 4.8 | - | collect_or_expand 8, grow_table 5 |
| r2/digest | 3.25 | 2.5 | 232 | 278.7 | 312.7 | 794.7 | 671.1 | 623 / 641 | 4.26 | TCPSocket 200.7, File 4.8 | - | collect_or_expand 8, grow_table 5 |
| r3/digest | 3.25 | 2.5 | 239.5 | 283.6 | 284.2 | 789.8 | 613.1 | 623 / 640 | 4.26 | TCPSocket 200.7, File 4.8 | - | collect_or_expand 8, grow_table 5 |
| r4/digest | 3.25 | 2.5 | 233.4 | 264.6 | 267.8 | 750.2 | 602.9 | 622 / 639 | 4.26 | TCPSocket 200.7, File 4.8 | - | collect_or_expand 8, grow_table 5 |
| r5/digest | 3.25 | 2.5 | 229 | 258.2 | 271.3 | 762.7 | 615.4 | 622 / 639 | 4.26 | TCPSocket 200.8, File 4.8 | - | collect_or_expand 8, grow_table 5 |
| r1/digest-socket | 2.5 | 2.5 | 265.4 | 323.8 | 323.8 | 671.1 | 730.6 | 623 / 640 | 4.25 | TCPSocket 200.5, File 4.8 | 200.5 | collect_or_expand 10 |
| r2/digest-socket | 2.5 | 2.5 | 260.7 | 394.3 | 394.3 | 674.2 | 675.3 | 623 / 640 | 4.26 | TCPSocket 200.8, File 4.8 | 200.8 | collect_or_expand 10 |
| r3/digest-socket | 2.5 | 2.5 | 215.5 | 259.6 | 259.6 | 561.6 | 553.6 | 623 / 640 | 4.26 | TCPSocket 200.7, File 4.8 | 200.7 | collect_or_expand 10 |
| r4/digest-socket | 2.5 | 2.5 | 235.5 | 300.9 | 300.9 | 605.5 | 614.4 | 623 / 640 | 4.26 | TCPSocket 200.9, File 4.8 | 200.9 | collect_or_expand 10 |
| r5/digest-socket | 2.5 | 2.5 | 240.8 | 273 | 273 | 583.7 | 620.8 | 622 / 639 | 4.26 | TCPSocket 200.7, File 4.8 | 200.7 | collect_or_expand 10 |
| r1/digest-socket-1k | 2.5 | 2.5 | 267.5 | 312.8 | 312.8 | 677.1 | 664.3 | 625 / 642 | 4.26 | TCPSocket 200.7, File 4.8 | 201.0 | collect_or_expand 10 |
| r2/digest-socket-1k | 2.5 | 2.5 | 235.2 | 298.8 | 298.8 | 580.8 | 588.5 | 625 / 642 | 4.27 | TCPSocket 201.1, File 4.8 | 201.1 | collect_or_expand 10 |
| r3/digest-socket-1k | 2.5 | 2.5 | 291.7 | 319.1 | 319.1 | 696.1 | 708.9 | 625 / 642 | 4.26 | TCPSocket 200.8, File 4.8 | 200.8 | collect_or_expand 10 |
| r4/digest-socket-1k | 2.5 | 2.5 | 242.2 | 328.8 | 328.8 | 607.4 | 612 | 623 / 640 | 4.25 | TCPSocket 200.5, File 4.8 | 200.5 | collect_or_expand 10 |
| r5/digest-socket-1k | 2.5 | 2.5 | 241 | 331.9 | 331.9 | 619.1 | 662.1 | 623 / 640 | 4.26 | TCPSocket 201, File 4.8 | 201.0 | collect_or_expand 10 |

| variant | runs | gcs/min | gcs/min 2nd half | p50 ms | max ms | GC ms/min | GC ms/min 2nd half | RSS med MB | TCPSocket reg/s | Digest reg/s | socket unreg/s | collections via grow_table / collect_or_expand (all runs) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| main | 5 | 4.5 | 2.5 | 235.9 | 308.6 | 1096 | 618.2 | 623 | 200.8 | 200.8 | - | 68 (73%) / 25 (27%) |
| main-socket | 5 | 6.75 | 7 | 231.8 | 296.7 | 1590.6 | 1646.3 | 556 | 200.9 | 200.9 | 200.9 | 135 (100%) / 0 (0%) |
| digest | 5 | 3.25 | 2.5 | 233.4 | 284.2 | 789.8 | 615.4 | 623 | 200.7 | 0 | - | 25 (38%) / 40 (62%) |
| digest-socket | 5 | 2.5 | 2.5 | 240.8 | 300.9 | 605.5 | 620.8 | 623 | 200.7 | 0 | 200.7 | 0 (0%) / 50 (100%) |
| digest-socket-1k | 5 | 2.5 | 2.5 | 242.2 | 319.1 | 619.1 | 662.1 | 625 | 200.8 | 0 | 201.0 | 0 (0%) / 50 (100%) |
