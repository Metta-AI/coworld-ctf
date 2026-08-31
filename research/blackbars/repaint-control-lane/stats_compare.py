import sys, json
from scipy.stats import fisher_exact

def main(n_a, banded_a, n_b, banded_b, label_a='A', label_b='B'):
    table = [[banded_a, n_a - banded_a], [banded_b, n_b - banded_b]]
    odds, p = fisher_exact(table)
    print(f"{label_a}: {banded_a}/{n_a} = {100*banded_a/n_a:.2f}%")
    print(f"{label_b}: {banded_b}/{n_b} = {100*banded_b/n_b:.2f}%")
    print(f"Fisher exact odds_ratio={odds:.3f} p={p:.4f}")

if __name__ == "__main__":
    n_a, banded_a, n_b, banded_b = map(int, sys.argv[1:5])
    la = sys.argv[5] if len(sys.argv) > 5 else 'A'
    lb = sys.argv[6] if len(sys.argv) > 6 else 'B'
    main(n_a, banded_a, n_b, banded_b, la, lb)
