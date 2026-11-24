import Foundation

/// Rutas seguras para la limpieza de IAs: expansión de globs limitada
/// a los directorios temporales y filtro de prefijos permitidos
/// ($HOME, $TMPDIR y /tmp, canonizados; nada de ".."). Lógica pura y
/// testeable — la usa `JunkStore` de la pestaña Mac.
public enum JunkPaths {
    /// Devuelve las rutas reales de `raw` (con globs expandidos solo en
    /// zonas temporales) que están dentro de las zonas permitidas.
    /// Los parámetros inyectables permiten testear sin tocar el home.
    public static func expand(_ raw: String,
                              home: String? = nil,
                              tmpDir: String? = nil,
                              tmpRoot: String? = nil) -> [String] {
        let fm = FileManager.default
        let homeP = home ?? fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let tmpP = tmpDir ?? URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let rootP = tmpRoot ?? URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path
        let tmpPrefix = tmpP.hasSuffix("/") ? tmpP : tmpP + "/"
        let rootPrefix = rootP.hasSuffix("/") ? rootP : rootP + "/"

        var candidates: [String] = []
        if raw.contains("*") {
            let parent = (raw as NSString).deletingLastPathComponent
            let pat = (raw as NSString).lastPathComponent
            let canonParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
            // Globs solo en los directorios temporales conocidos.
            guard canonParent == tmpP || canonParent == rootP
                    || canonParent.hasPrefix(rootPrefix)
                    || canonParent.hasPrefix(tmpPrefix) else { return [] }
            let kids = (try? fm.contentsOfDirectory(atPath: canonParent)) ?? []
            let pred = NSPredicate(format: "SELF LIKE[c] %@", pat)
            candidates = kids.filter { pred.evaluate(with: $0) }
                .map { (canonParent as NSString).appendingPathComponent($0) }
        } else {
            candidates = [raw]
        }

        var out: [String] = []
        for p in candidates {
            let r = URL(fileURLWithPath: (p as NSString).standardizingPath)
                .resolvingSymlinksInPath().path
            guard r != "/", r != homeP else { continue }
            let ok = r == homeP || r.hasPrefix(homeP + "/")
                || r == tmpP || r.hasPrefix(tmpPrefix)
                || r == rootP || r.hasPrefix(rootPrefix)
            if ok && !out.contains(r) { out.append(r) }
        }
        return out
    }
}
