#if canImport(Foundation)
import Foundation

// MARK: - Aritmética segura del lanzador

/// Evaluador aritmético seguro (descenso recursivo). Sustituye a
/// NSExpression, que LANZA excepción ObjC con entradas como «2++3»
/// y en Swift eso es un crash no recuperable de la app.
public struct Arith {
    public static func eval(_ input: String) -> Double? {
        var p = P(chars: Array(input.filter { !$0.isWhitespace }))
        guard let v = p.add(), p.i == p.chars.count else { return nil }
        return v.isFinite ? v : nil
    }

    private struct P {
        let chars: [Character]
        var i = 0

        private mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }
        private mutating func next() -> Character? {
            guard i < chars.count else { return nil }
            defer { i += 1 }
            return chars[i]
        }

        /// suma/resta (menor precedencia)
        mutating func add() -> Double? {
            guard var v = mul() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                _ = next()
                guard let r = mul() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }

        /// multiplicación/división
        mutating func mul() -> Double? {
            guard var v = factor() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                _ = next()
                guard let r = factor() else { return nil }
                if c == "/" { guard r != 0 else { return nil }; v /= r } else { v *= r }
            }
            return v
        }

        /// paréntesis, unario y número
        mutating func factor() -> Double? {
            if peek() == "(" {
                _ = next()
                guard let v = add(), next() == ")" else { return nil }
                return v
            }
            if peek() == "-" {
                _ = next()
                guard let v = factor() else { return nil }
                return -v
            }
            // Sin unario «+»: «2++3» es un typo del usuario y debe
            // dar nil (no calcular5 en silencio); «-5» sí se soporta.
            return num()
        }

        private mutating func num() -> Double? {
            var end = i
            var dot = false
            var digits = 0
            while end < chars.count {
                let c = chars[end]
                if c.isNumber { digits += 1; end += 1 }
                else if c == ".", !dot { dot = true; end += 1 }
                else { break }
            }
            guard digits > 0 else { return nil }
            let v = Double(String(chars[i..<end]))
            i = end
            return v
        }
    }
}
#endif
