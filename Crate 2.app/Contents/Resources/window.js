ObjC.import('Cocoa'); ObjC.import('WebKit');
function run(argv){
const res=argv[0], url=argv[1];
const app=$.NSApplication.sharedApplication;
app.setActivationPolicy($.NSApplicationActivationPolicyRegular);
try{app.applicationIconImage=$.NSImage.alloc.initByReferencingFile(res+'/Crate.png')}catch(e){}
ObjC.registerSubclass({name:'CrateDelegate',superclass:'NSObject',protocols:['NSApplicationDelegate'],methods:{
 'applicationShouldTerminateAfterLastWindowClosed:':{types:['bool',['id']],implementation:function(){return true}}}});
app.delegate=$.CrateDelegate.alloc.init;
const bar=$.NSMenu.alloc.init, top=$.NSMenuItem.alloc.init; bar.addItem(top);
const sub=$.NSMenu.alloc.init; sub.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('Quit Crate','terminate:','q'));
top.submenu=sub; app.mainMenu=bar;
const win=$.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0,0,1240,820),15,2,false);
win.title='Crate'; win.releasedWhenClosed=false;
const wv=$.WKWebView.alloc.initWithFrameConfiguration(win.contentView.bounds,$.WKWebViewConfiguration.alloc.init);
wv.autoresizingMask=18; win.contentView.addSubview(wv);
wv.loadRequest($.NSURLRequest.requestWithURL($.NSURL.URLWithString(url)));
win.center; win.makeKeyAndOrderFront(null); app.activateIgnoringOtherApps(true); app.run;
}
