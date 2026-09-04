/// LaTeX command → Unicode glyph table for the pure-Swift math renderer.
/// Names are stored without the leading backslash.
enum LaTeXSymbols {
    static let names: [String: String] = [
        // Greek lower
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ",
        "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        // Greek upper
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ",
        "Psi": "Ψ", "Omega": "Ω",
        // Binary operators
        "times": "×", "div": "÷", "pm": "±", "mp": "∓", "cdot": "⋅",
        "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "•",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "oslash": "⊘",
        "odot": "⊙", "dagger": "†", "ddagger": "‡", "amalg": "⨿",
        // Relations
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡",
        "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝",
        "ll": "≪", "gg": "≫", "prec": "≺", "succ": "≻",
        "preceq": "≼", "succeq": "≽", "subset": "⊂", "supset": "⊃",
        "subseteq": "⊆", "supseteq": "⊇", "in": "∈", "notin": "∉",
        "ni": "∋", "perp": "⊥", "parallel": "∥", "asymp": "≍",
        "doteq": "≐", "models": "⊨",
        // Arrows
        "to": "→", "rightarrow": "→", "longrightarrow": "⟶",
        "leftarrow": "←", "gets": "←", "longleftarrow": "⟵",
        "Leftarrow": "⇒", "Rightarrow": "⇒", "Longrightarrow": "⟹",
        "leftrightarrow": "↔", "Leftrightarrow": "⇔",
        "mapsto": "↦", "hookrightarrow": "↪", "uparrow": "↑",
        "downarrow": "↓", "updownarrow": "↕", "nearrow": "↗",
        "searrow": "↘", "swarrow": "↙", "nwarrow": "↖",
        "rightharpoonup": "⇀", "leftharpoonup": "↼",
        // Big operators
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫",
        "iint": "∬", "iiint": "∭", "oint": "∮",
        "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂",
        // Misc symbols
        "infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀",
        "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
        "land": "∧", "lor": "∨", "emptyset": "∅", "varnothing": "∅",
        "angle": "∠", "triangle": "△", "square": "□", "diamond": "⋄",
        "prime": "′", "backslash": "\\",
        "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮",
        "ddots": "⋱", "aleph": "ℵ", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "wp": "℘", "deg": "°",
        "copyright": "©", "pounds": "£", "euro": "€", "checkmark": "✓",
        // Spacing (rendered as width gaps, listed here for the parser)
        "quad": "\u{2003}", "qquad": "\u{2003}\u{2003}",
        " ": " ", "thinspace": "\u{2009}",
    ]
}
