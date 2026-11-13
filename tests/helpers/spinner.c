/* Burn CPU until stopped. */
int main(void)
{
    volatile unsigned long n;

    n = 0;
    for (;;) {
        n++;
    }
}
