//%attributes = {}
$scheme:="fourd"

$method:="MYCALLBACK"

REGISTER PROTOCOL($scheme; $method)

var $file : 4D:C1709.File

$file:=Folder:C1567(fk resources folder:K87:11).file("template.html")

var $HTML : Text

$HTML:=$file.getText()

PROCESS 4D TAGS:C816($HTML; $HTML; $scheme)

$file:=Folder:C1567(fk resources folder:K87:11).file("example.html")

$file.setText($HTML)

OPEN URL:C673($file.platformPath)