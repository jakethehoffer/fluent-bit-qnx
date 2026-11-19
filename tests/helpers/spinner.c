/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Jake Hoffman */

/* Burn CPU until stopped. */
int main(void)
{
    volatile unsigned long n;

    n = 0;
    for (;;) {
        n++;
    }
}
