# Routing benchmark summary

Generated from `reports/routing/2026-10-28/summary.json`. Raw per-seed counts, configs and full stats accompany this table.

Intervals are unadjusted seed-paired 95% t intervals, n=3. All strategies remain unpromoted.

| Split / scenario / power | Strategy | ≤5 % | Delivery % | ≤3 % | Mean/p95 hops | Relays | p95 ms | Retry/exhausted | NORMAL/SUPER %/h | Flap/node/min | Δ≤5 pp [95% CI] |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| train / campus_quad / always | ack-2000-v1 | 99.33 | 99.33 | 94.67 | 1.84/3.3 | 4206 | 2436 | 34.0/4.0 | 2.512/6.706 | 0.099 | +0.00 [-1.66, +1.66] |
| train / campus_quad / always | ack-6000-v1 | 99.78 | 99.78 | 93.78 | 1.90/3.7 | 3935 | 3080 | 24.7/3.0 | 2.567/6.956 | 0.077 | +0.44 [-0.51, +1.40] |
| train / campus_quad / always | baseline-v1 | 99.33 | 99.78 | 92.67 | 1.92/3.7 | 4226 | 3233 | 19.3/2.3 | 2.567/6.956 | 0.077 | +0.00 [+0.00, +0.00] |
| train / campus_quad / always | community-carrier-v1 | 99.56 | 99.78 | 92.44 | 1.92/3.7 | 4023 | 2361 | 17.0/2.3 | 2.567/6.956 | 0.077 | +0.22 [-0.73, +1.18] |
| train / campus_quad / always | route-flood-v1 | 99.56 | 99.78 | 92.22 | 1.93/3.7 | 6001 | 1125 | 14.7/0.3 | 2.534/6.956 | 0.086 | +0.22 [-0.73, +1.18] |
| train / campus_quad / always | super-carrier-v1 | 99.33 | 99.78 | 93.33 | 1.92/3.7 | 4134 | 2283 | 16.3/2.0 | 2.567/6.956 | 0.094 | +0.00 [+0.00, +0.00] |
| train / campus_quad / duty | ack-2000-v1 | 98.89 | 98.89 | 91.56 | 1.90/3.7 | 5226 | 2075 | 42.3/7.7 | 1.197/6.665 | 0.099 | -0.67 [-3.98, +2.65] |
| train / campus_quad / duty | ack-6000-v1 | 99.33 | 99.56 | 93.56 | 1.87/3.7 | 3697 | 2912 | 23.0/3.0 | 1.290/6.860 | 0.077 | -0.22 [-2.75, +2.31] |
| train / campus_quad / duty | baseline-v1 | 99.56 | 99.56 | 93.33 | 1.88/3.7 | 4239 | 4205 | 22.3/2.3 | 1.218/6.665 | 0.107 | +0.00 [+0.00, +0.00] |
| train / campus_quad / duty | community-carrier-v1 | 100.00 | 100.00 | 93.56 | 1.88/3.7 | 4056 | 2273 | 18.0/2.3 | 1.218/6.763 | 0.094 | +0.44 [-1.47, +2.36] |
| train / campus_quad / duty | route-flood-v1 | 100.00 | 100.00 | 93.78 | 1.90/3.7 | 6039 | 2046 | 16.3/2.7 | 1.270/6.787 | 0.090 | +0.44 [-1.47, +2.36] |
| train / campus_quad / duty | super-carrier-v1 | 99.33 | 99.56 | 94.00 | 1.87/3.7 | 3914 | 2349 | 18.7/2.0 | 1.309/6.860 | 0.094 | -0.22 [-1.18, +0.73] |
| train / sparse_village / always | ack-2000-v1 | 27.56 | 27.56 | 27.56 | 1.02/1.0 | 1465 | 380 | 216.3/106.7 | 2.712/2.194 | 0.072 | +0.00 [+0.00, +0.00] |
| train / sparse_village / always | ack-6000-v1 | 27.56 | 27.56 | 27.56 | 1.03/1.3 | 1414 | 335 | 211.0/101.0 | 2.712/2.194 | 0.064 | +0.00 [+0.00, +0.00] |
| train / sparse_village / always | baseline-v1 | 27.56 | 27.56 | 27.56 | 1.01/1.0 | 1447 | 309 | 213.0/103.7 | 2.712/2.319 | 0.064 | +0.00 [+0.00, +0.00] |
| train / sparse_village / always | community-carrier-v1 | 27.56 | 27.56 | 27.56 | 1.01/1.0 | 1489 | 312 | 214.7/103.7 | 2.712/2.319 | 0.064 | +0.00 [+0.00, +0.00] |
| train / sparse_village / always | route-flood-v1 | 27.56 | 27.56 | 27.56 | 1.03/1.3 | 3914 | 1647 | 214.7/103.7 | 2.712/1.944 | 0.079 | +0.00 [+0.00, +0.00] |
| train / sparse_village / always | super-carrier-v1 | 27.56 | 27.56 | 27.56 | 1.01/1.0 | 1571 | 1608 | 214.0/103.7 | 2.712/2.319 | 0.064 | +0.00 [+0.00, +0.00] |
| train / sparse_village / duty | ack-2000-v1 | 27.56 | 27.56 | 27.56 | 1.02/1.0 | 1465 | 380 | 216.3/106.7 | 1.288/2.139 | 0.072 | +0.00 [+0.00, +0.00] |
| train / sparse_village / duty | ack-6000-v1 | 27.56 | 27.56 | 27.56 | 1.03/1.3 | 1415 | 335 | 211.0/101.0 | 1.288/2.139 | 0.064 | +0.00 [+0.00, +0.00] |
| train / sparse_village / duty | baseline-v1 | 27.56 | 27.56 | 27.56 | 1.01/1.0 | 1447 | 309 | 213.0/103.7 | 1.288/2.286 | 0.064 | +0.00 [+0.00, +0.00] |
| train / sparse_village / duty | community-carrier-v1 | 27.56 | 27.56 | 27.56 | 1.03/1.3 | 1493 | 472 | 213.7/103.7 | 1.288/2.286 | 0.057 | +0.00 [+0.00, +0.00] |
| train / sparse_village / duty | route-flood-v1 | 27.56 | 27.56 | 27.56 | 1.03/1.3 | 3914 | 1647 | 214.7/103.7 | 1.288/1.845 | 0.079 | +0.00 [+0.00, +0.00] |
| train / sparse_village / duty | super-carrier-v1 | 27.56 | 27.56 | 27.56 | 1.02/1.0 | 1538 | 314 | 212.3/103.7 | 1.288/2.286 | 0.064 | +0.00 [+0.00, +0.00] |
| train / festival_crowd / always | ack-2000-v1 | 84.22 | 92.89 | 63.11 | 2.82/6.0 | 44030 | 9817 | 122.7/44.3 | 2.916/6.441 | 0.126 | -3.11 [-17.20, +10.97] |
| train / festival_crowd / always | ack-6000-v1 | 88.22 | 94.00 | 64.89 | 2.82/6.0 | 40010 | 9182 | 94.3/32.3 | 2.912/6.219 | 0.123 | +0.89 [-3.89, +5.67] |
| train / festival_crowd / always | baseline-v1 | 87.33 | 95.33 | 63.56 | 2.87/6.0 | 39062 | 8692 | 98.0/36.3 | 2.915/6.405 | 0.123 | +0.00 [+0.00, +0.00] |
| train / festival_crowd / always | community-carrier-v1 | 86.00 | 94.89 | 62.44 | 2.92/6.0 | 38684 | 6965 | 93.3/36.0 | 2.927/6.341 | 0.127 | -1.33 [-4.65, +1.98] |
| train / festival_crowd / always | route-flood-v1 | 87.78 | 95.56 | 63.78 | 2.87/5.7 | 78278 | 5934 | 81.3/30.0 | 2.850/6.576 | 0.116 | +0.44 [-13.44, +14.33] |
| train / festival_crowd / always | super-carrier-v1 | 86.89 | 93.78 | 60.44 | 2.89/6.0 | 40486 | 6162 | 98.7/37.3 | 2.886/6.387 | 0.129 | -0.44 [-8.27, +7.38] |
| train / festival_crowd / duty | ack-2000-v1 | 85.33 | 95.33 | 61.78 | 2.94/6.0 | 48465 | 4866 | 126.7/42.0 | 1.465/6.160 | 0.116 | +0.22 [-7.60, +8.05] |
| train / festival_crowd / duty | ack-6000-v1 | 87.11 | 93.11 | 62.44 | 2.81/5.7 | 38235 | 9411 | 91.3/32.0 | 1.456/6.294 | 0.114 | +2.00 [-9.59, +13.59] |
| train / festival_crowd / duty | baseline-v1 | 85.11 | 92.89 | 64.22 | 2.82/5.7 | 38081 | 7996 | 88.3/34.0 | 1.389/6.452 | 0.093 | +0.00 [+0.00, +0.00] |
| train / festival_crowd / duty | community-carrier-v1 | 86.00 | 94.44 | 63.78 | 2.86/6.0 | 37711 | 9519 | 97.7/38.3 | 1.388/6.379 | 0.112 | +0.89 [-9.23, +11.01] |
| train / festival_crowd / duty | route-flood-v1 | 86.00 | 93.56 | 62.22 | 2.86/6.0 | 78949 | 19756 | 98.0/35.7 | 1.603/6.014 | 0.139 | +0.89 [-18.87, +20.65] |
| train / festival_crowd / duty | super-carrier-v1 | 82.22 | 92.22 | 59.78 | 2.94/6.0 | 39119 | 8134 | 108.0/42.0 | 1.457/6.399 | 0.110 | -2.89 [-14.64, +8.86] |
| train / partitioned_pair / always | ack-2000-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 1863 | 308 | 170.7/83.3 | 2.124/4.637 | 0.052 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / always | ack-6000-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 1829 | 312 | 165.7/78.0 | 2.124/4.637 | 0.052 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / always | baseline-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 1835 | 315 | 168.7/80.3 | 2.315/2.319 | 0.060 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / always | community-carrier-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 2027 | 315 | 167.7/80.3 | 2.159/4.637 | 0.086 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / always | route-flood-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 5164 | 1617 | 171.0/80.3 | 2.124/4.387 | 0.069 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / always | super-carrier-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 2037 | 1631 | 169.0/80.3 | 2.124/4.637 | 0.052 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / duty | ack-2000-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 1863 | 308 | 170.7/83.3 | 1.008/4.572 | 0.052 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / duty | ack-6000-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 1829 | 312 | 165.7/78.0 | 1.008/4.572 | 0.052 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / duty | baseline-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 1835 | 315 | 168.7/80.3 | 1.249/2.286 | 0.060 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / duty | community-carrier-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 2011 | 312 | 168.3/80.3 | 1.008/4.572 | 0.052 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / duty | route-flood-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 5164 | 1617 | 171.0/80.3 | 1.008/4.278 | 0.069 | +0.00 [+0.00, +0.00] |
| train / partitioned_pair / duty | super-carrier-v1 | 43.33 | 43.33 | 43.33 | 1.00/1.0 | 2037 | 315 | 167.7/80.3 | 1.008/4.572 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / campus_quad / always | ack-2000-v1 | 99.78 | 100.00 | 91.78 | 1.96/3.7 | 4776 | 2412 | 37.7/4.7 | 2.639/6.123 | 0.137 | +0.44 [-2.09, +2.97] |
| validation / campus_quad / always | ack-6000-v1 | 99.78 | 99.78 | 92.22 | 1.95/4.0 | 3580 | 4776 | 27.0/3.0 | 2.532/6.049 | 0.146 | +0.44 [-2.09, +2.97] |
| validation / campus_quad / always | baseline-v1 | 99.33 | 99.33 | 91.78 | 1.97/4.0 | 4155 | 2646 | 29.7/5.3 | 2.506/6.956 | 0.099 | +0.00 [+0.00, +0.00] |
| validation / campus_quad / always | community-carrier-v1 | 99.33 | 99.33 | 92.44 | 1.97/4.0 | 4179 | 3433 | 26.3/3.7 | 2.478/6.752 | 0.107 | +0.00 [-1.66, +1.66] |
| validation / campus_quad / always | route-flood-v1 | 99.78 | 100.00 | 92.00 | 1.96/4.0 | 5880 | 2102 | 15.0/0.7 | 2.591/6.019 | 0.150 | +0.44 [-2.09, +2.97] |
| validation / campus_quad / always | super-carrier-v1 | 99.56 | 99.56 | 91.56 | 1.98/4.0 | 4618 | 4414 | 28.0/4.0 | 2.500/6.484 | 0.120 | +0.22 [-1.69, +2.13] |
| validation / campus_quad / duty | ack-2000-v1 | 99.78 | 99.78 | 92.89 | 1.95/4.0 | 4790 | 1700 | 32.7/2.7 | 1.583/3.398 | 0.150 | -0.22 [-1.18, +0.73] |
| validation / campus_quad / duty | ack-6000-v1 | 99.33 | 99.56 | 92.44 | 1.95/3.7 | 4154 | 4786 | 25.7/1.7 | 1.213/6.164 | 0.120 | -0.67 [-3.54, +2.20] |
| validation / campus_quad / duty | baseline-v1 | 100.00 | 100.00 | 91.11 | 2.00/4.0 | 4086 | 3501 | 27.3/4.0 | 1.214/5.654 | 0.159 | +0.00 [+0.00, +0.00] |
| validation / campus_quad / duty | community-carrier-v1 | 99.33 | 99.33 | 92.00 | 1.98/4.0 | 4248 | 3404 | 26.7/4.7 | 1.303/6.157 | 0.150 | -0.67 [-2.32, +0.99] |
| validation / campus_quad / duty | route-flood-v1 | 100.00 | 100.00 | 92.67 | 1.96/3.7 | 6273 | 3246 | 21.7/2.3 | 1.270/6.202 | 0.133 | +0.00 [+0.00, +0.00] |
| validation / campus_quad / duty | super-carrier-v1 | 98.89 | 98.89 | 91.78 | 1.97/4.0 | 4169 | 3431 | 30.7/5.7 | 1.453/6.421 | 0.159 | -1.11 [-4.56, +2.34] |
| validation / sparse_village / always | ack-2000-v1 | 25.11 | 25.11 | 25.11 | 1.00/1.0 | 1576 | 939 | 225.3/110.7 | 2.835/2.319 | 0.064 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / always | ack-6000-v1 | 25.11 | 25.11 | 25.11 | 1.00/1.0 | 1540 | 313 | 219.0/104.3 | 2.717/4.774 | 0.057 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / always | baseline-v1 | 25.11 | 25.11 | 25.11 | 1.00/1.0 | 1548 | 1629 | 221.3/107.0 | 2.835/2.319 | 0.050 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / always | community-carrier-v1 | 25.11 | 25.11 | 25.11 | 1.02/1.3 | 1667 | 1786 | 222.0/107.0 | 2.692/4.774 | 0.043 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / always | route-flood-v1 | 25.11 | 25.11 | 25.11 | 1.00/1.0 | 4036 | 1601 | 222.3/107.0 | 2.717/4.774 | 0.057 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / always | super-carrier-v1 | 25.11 | 25.11 | 25.11 | 1.02/1.3 | 1735 | 482 | 222.0/107.0 | 2.692/4.774 | 0.043 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / duty | ack-2000-v1 | 25.11 | 25.11 | 25.11 | 1.00/1.0 | 1576 | 939 | 225.3/110.7 | 1.457/2.286 | 0.064 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / duty | ack-6000-v1 | 25.11 | 25.11 | 25.11 | 1.00/1.0 | 1540 | 313 | 219.0/104.3 | 1.308/4.701 | 0.057 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / duty | baseline-v1 | 25.11 | 25.11 | 25.11 | 1.00/1.0 | 1548 | 1629 | 221.3/107.0 | 1.458/2.286 | 0.050 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / duty | community-carrier-v1 | 25.11 | 25.11 | 25.11 | 1.01/1.0 | 1640 | 315 | 221.3/107.0 | 1.279/4.701 | 0.043 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / duty | route-flood-v1 | 25.11 | 25.11 | 25.11 | 1.00/1.0 | 4036 | 1601 | 222.3/107.0 | 1.308/4.701 | 0.057 | +0.00 [+0.00, +0.00] |
| validation / sparse_village / duty | super-carrier-v1 | 25.11 | 25.11 | 25.11 | 1.01/1.0 | 1751 | 315 | 221.7/107.0 | 1.338/4.701 | 0.057 | +0.00 [+0.00, +0.00] |
| validation / festival_crowd / always | ack-2000-v1 | 86.00 | 93.11 | 63.56 | 2.85/6.0 | 44672 | 34078 | 133.0/45.7 | 2.963/6.264 | 0.134 | +4.67 [-8.48, +17.81] |
| validation / festival_crowd / always | ack-6000-v1 | 84.89 | 92.00 | 59.78 | 2.88/6.0 | 33605 | 24778 | 104.3/35.0 | 2.942/6.276 | 0.126 | +3.56 [-8.98, +16.10] |
| validation / festival_crowd / always | baseline-v1 | 81.33 | 88.00 | 56.89 | 2.81/5.7 | 32953 | 45111 | 134.0/51.3 | 2.909/6.395 | 0.124 | +0.00 [+0.00, +0.00] |
| validation / festival_crowd / always | community-carrier-v1 | 77.11 | 84.22 | 54.89 | 2.78/5.7 | 33648 | 24156 | 135.0/52.7 | 2.873/6.495 | 0.126 | -4.22 [-22.39, +13.94] |
| validation / festival_crowd / always | route-flood-v1 | 77.11 | 83.56 | 55.78 | 2.77/6.0 | 86365 | 28732 | 119.3/46.7 | 2.878/6.537 | 0.107 | -4.22 [-42.14, +33.70] |
| validation / festival_crowd / always | super-carrier-v1 | 72.89 | 76.44 | 53.78 | 2.56/5.3 | 37270 | 7842 | 128.0/49.0 | 2.933/6.408 | 0.136 | -8.44 [-52.77, +35.88] |
| validation / festival_crowd / duty | ack-2000-v1 | 77.78 | 84.22 | 57.78 | 2.75/5.7 | 43511 | 47303 | 152.7/60.0 | 1.526/5.934 | 0.123 | +2.67 [-9.28, +14.61] |
| validation / festival_crowd / duty | ack-6000-v1 | 74.22 | 80.44 | 56.22 | 2.71/5.7 | 32524 | 33078 | 134.7/54.3 | 1.507/6.016 | 0.127 | -0.89 [-21.73, +19.95] |
| validation / festival_crowd / duty | baseline-v1 | 75.11 | 79.11 | 54.67 | 2.66/5.7 | 33351 | 35093 | 140.3/58.0 | 1.573/6.020 | 0.113 | +0.00 [+0.00, +0.00] |
| validation / festival_crowd / duty | community-carrier-v1 | 75.11 | 80.00 | 54.67 | 2.71/5.7 | 34385 | 36600 | 134.7/53.7 | 1.525/6.368 | 0.113 | +0.00 [+0.00, +0.00] |
| validation / festival_crowd / duty | route-flood-v1 | 77.11 | 84.67 | 55.78 | 2.80/5.7 | 87142 | 35135 | 125.0/50.7 | 1.460/6.017 | 0.112 | +2.00 [-15.91, +19.91] |
| validation / festival_crowd / duty | super-carrier-v1 | 78.89 | 82.67 | 55.33 | 2.69/5.0 | 34877 | 11577 | 121.3/47.0 | 1.595/5.737 | 0.119 | +3.78 [-3.69, +11.25] |
| validation / partitioned_pair / always | ack-2000-v1 | 42.22 | 42.22 | 42.22 | 1.00/1.0 | 1865 | 309 | 174.3/85.7 | 2.394/4.637 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / always | ack-6000-v1 | 42.22 | 42.22 | 42.22 | 1.00/1.0 | 1850 | 310 | 170.3/80.7 | 2.394/4.637 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / always | baseline-v1 | 42.22 | 42.22 | 42.22 | 1.00/1.0 | 1867 | 315 | 171.7/83.0 | 2.394/4.637 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / always | community-carrier-v1 | 42.22 | 42.22 | 42.22 | 1.00/1.0 | 2027 | 313 | 171.0/83.0 | 2.394/4.637 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / always | route-flood-v1 | 42.22 | 42.22 | 42.22 | 1.01/1.0 | 5257 | 315 | 171.3/83.0 | 2.394/4.637 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / always | super-carrier-v1 | 42.22 | 42.22 | 42.22 | 1.00/1.0 | 2046 | 315 | 172.7/83.0 | 2.394/4.637 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / duty | ack-2000-v1 | 42.22 | 42.22 | 42.22 | 1.00/1.0 | 1865 | 309 | 174.3/85.7 | 1.138/4.576 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / duty | ack-6000-v1 | 42.22 | 42.22 | 42.22 | 1.00/1.0 | 1850 | 310 | 170.3/80.7 | 1.138/4.576 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / duty | baseline-v1 | 42.22 | 42.22 | 42.22 | 1.00/1.0 | 1867 | 315 | 171.7/83.0 | 1.138/4.576 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / duty | community-carrier-v1 | 42.22 | 42.22 | 42.22 | 1.00/1.0 | 2016 | 315 | 171.3/83.0 | 1.138/4.576 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / duty | route-flood-v1 | 42.22 | 42.22 | 42.22 | 1.01/1.0 | 5257 | 315 | 171.3/83.0 | 1.138/4.576 | 0.052 | +0.00 [+0.00, +0.00] |
| validation / partitioned_pair / duty | super-carrier-v1 | 42.22 | 42.22 | 42.22 | 1.00/1.0 | 2040 | 310 | 171.0/83.0 | 1.138/4.576 | 0.052 | +0.00 [+0.00, +0.00] |

## Nondominated sets

Per context over mean five-hop delivery (maximize), relay transmissions, p95 latency and NORMAL energy (minimize). This exploratory Pareto set ignores worst-seed regressions; it is not permission to deploy.

* ('train', 'campus_quad', False): ack-2000-v1, ack-6000-v1, community-carrier-v1, route-flood-v1, super-carrier-v1
* ('train', 'campus_quad', True): ack-2000-v1, ack-6000-v1, community-carrier-v1, route-flood-v1, super-carrier-v1
* ('train', 'sparse_village', False): ack-6000-v1, baseline-v1
* ('train', 'sparse_village', True): ack-6000-v1, baseline-v1
* ('train', 'festival_crowd', False): ack-6000-v1, baseline-v1, community-carrier-v1, route-flood-v1, super-carrier-v1
* ('train', 'festival_crowd', True): ack-2000-v1, ack-6000-v1, baseline-v1, community-carrier-v1
* ('train', 'partitioned_pair', False): ack-2000-v1, ack-6000-v1
* ('train', 'partitioned_pair', True): ack-2000-v1, ack-6000-v1
* ('validation', 'campus_quad', False): ack-2000-v1, ack-6000-v1, baseline-v1, community-carrier-v1, route-flood-v1, super-carrier-v1
* ('validation', 'campus_quad', True): ack-2000-v1, ack-6000-v1, baseline-v1, community-carrier-v1, route-flood-v1, super-carrier-v1
* ('validation', 'sparse_village', False): ack-6000-v1, community-carrier-v1, super-carrier-v1
* ('validation', 'sparse_village', True): ack-6000-v1, community-carrier-v1
* ('validation', 'festival_crowd', False): ack-2000-v1, ack-6000-v1, baseline-v1, community-carrier-v1, super-carrier-v1
* ('validation', 'festival_crowd', True): ack-2000-v1, ack-6000-v1, baseline-v1, community-carrier-v1, route-flood-v1, super-carrier-v1
* ('validation', 'partitioned_pair', False): ack-2000-v1, ack-6000-v1
* ('validation', 'partitioned_pair', True): ack-2000-v1, ack-6000-v1

## Promotion screen

* **ack-2000-v1: not-promoted** — five-hop regression on a held-out seed/context; increased relay budget requires owner review; increased NORMAL energy estimate requires owner review; increased p95 latency needs release-budget evaluation; role instability increased; no positive seed-paired 95% interval in any validation context; authoritative Dart candidate/OOD/release gate verification required.
* **ack-6000-v1: not-promoted** — five-hop regression on a held-out seed/context; increased relay budget requires owner review; increased NORMAL energy estimate requires owner review; increased p95 latency needs release-budget evaluation; role instability increased; no positive seed-paired 95% interval in any validation context; authoritative Dart candidate/OOD/release gate verification required.
* **community-carrier-v1: not-promoted** — five-hop regression on a held-out seed/context; increased relay budget requires owner review; increased NORMAL energy estimate requires owner review; increased p95 latency needs release-budget evaluation; role instability increased; no positive seed-paired 95% interval in any validation context; authoritative Dart candidate/OOD/release gate verification required.
* **route-flood-v1: not-promoted** — five-hop regression on a held-out seed/context; increased relay budget requires owner review; increased NORMAL energy estimate requires owner review; increased p95 latency needs release-budget evaluation; role instability increased; no positive seed-paired 95% interval in any validation context; authoritative Dart candidate/OOD/release gate verification required.
* **super-carrier-v1: not-promoted** — five-hop regression on a held-out seed/context; increased relay budget requires owner review; increased NORMAL energy estimate requires owner review; increased p95 latency needs release-budget evaluation; role instability increased; no positive seed-paired 95% interval in any validation context; authoritative Dart candidate/OOD/release gate verification required.

## Equal-context aggregate (never substitutes for per-scenario safety)

| Split | Strategy | Mean ≤5 % | Worst context % | Worst paired Δ pp | Mean Δ pp [95% seed-block CI] | Relay sum |
|---|---|---:|---:|---:|---|---:|
| train | ack-2000-v1 | 63.69 | 27.56 | -8.67 | -0.44 [-2.13, +1.24] | 325750 |
| train | ack-6000-v1 | 64.53 | 27.56 | -2.67 | +0.39 [-2.03, +2.81] | 277093 |
| train | baseline-v1 | 64.14 | 27.56 | +0.00 | +0.00 [+0.00, +0.00] | 276511 |
| train | community-carrier-v1 | 64.17 | 27.56 | -2.67 | +0.03 [-1.73, +1.79] | 274486 |
| train | route-flood-v1 | 64.39 | 27.56 | -6.00 | +0.25 [-0.90, +1.40] | 562268 |
| train | super-carrier-v1 | 63.69 | 27.56 | -8.00 | -0.44 [-2.75, +1.86] | 284504 |
| validation | ack-2000-v1 | 62.25 | 25.11 | -1.33 | +0.94 [-1.18, +3.07] | 313896 |
| validation | ack-6000-v1 | 61.61 | 25.11 | -8.67 | +0.31 [-2.20, +2.81] | 241929 |
| validation | baseline-v1 | 61.31 | 25.11 | +0.00 | +0.00 [+0.00, +0.00] | 244122 |
| validation | community-carrier-v1 | 60.69 | 25.11 | -12.67 | -0.61 [-2.73, +1.50] | 251428 |
| validation | route-flood-v1 | 61.08 | 25.11 | -21.33 | -0.22 [-6.38, +5.93] | 612735 |
| validation | super-carrier-v1 | 60.61 | 25.11 | -23.33 | -0.69 [-6.82, +5.43] | 265522 |
