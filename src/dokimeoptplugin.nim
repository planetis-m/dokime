import plugins
import dokime/private/queryplugin

let root = loadPluginInput()
saveTree generate(root, qmOpt)
