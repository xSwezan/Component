wally install
rojo sourcemap --output sourcemap.json
wally-package-types --sourcemap sourcemap.json Packages
wally-package-types --sourcemap sourcemap.json ServerPackages