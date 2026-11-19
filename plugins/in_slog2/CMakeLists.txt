# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Jake Hoffman

set(src
  in_slog2.c)

FLB_PLUGIN(in_slog2 "${src}" "slog2parse")
