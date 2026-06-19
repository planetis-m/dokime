import plugins
import ".." / queryplugin

let root = loadPluginInput()
saveTree generate(root, qmExec)
