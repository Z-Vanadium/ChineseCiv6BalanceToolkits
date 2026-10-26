"""Materialize our native FE baseline and narrow CCB integration; never edit game files."""
from pathlib import Path
import hashlib,json
ROOT=Path(__file__).resolve().parents[1]
GAME=Path("F:/Steam/steamapps/common/Sid Meier's Civilization VI/Base/Assets/UI/FrontEnd")
OUT=ROOT/"MPH/ModCheck/UI"
def generate():
    OUT.mkdir(parents=True,exist_ok=True)
    inputs={"StagingRoom.lua":GAME/"Multiplayer/StagingRoom.lua","StagingRoom.xml":GAME/"Multiplayer/StagingRoom.xml","MainMenu.lua":GAME/"MainMenu.lua","MainMenu.xml":GAME/"MainMenu.xml"}
    hashes={}
    for name,src in inputs.items():
        raw=src.read_bytes();hashes[name]=hashlib.sha256(raw).hexdigest();s=raw.decode("utf-8-sig")
        if name.endswith('.lua'):
            module="CCBModCheckStaging" if name.startswith('Staging') else "CCBModCheckMainMenu"
            marker='Initialize();'
            assert s.rstrip().endswith(marker),name
            pos=s.rfind(marker);s=s[:pos]+f'include("{module}");\n{module}.Install();\n'+s[pos:]
        elif name=='StagingRoom.xml':
            marker='<!-- Ready Button -->';assert s.count(marker)==1
            lamp='''<Button ID="CCBModCheckLight" Anchor="L,C" Offset="766,0" Size="24,34" Hidden="1" NoStateChange="1">
                <Label ID="CCBModCheckLampLabel" Anchor="C,C" Style="FontNormal20" String="?" />
            </Button>\n            '''
            s=s.replace(marker,lamp+marker).replace('Offset="755,0" Texture="Shell_ReadyCheckbox"','Offset="795,0" Texture="Shell_ReadyCheckbox"').replace('Offset="793,0" Style="FontNormalMedium14"','Offset="833,0" Style="FontNormalMedium14"').replace('WrapWidth="120"','WrapWidth="90"')
            marker='<Container ID="TooltipContainer"'
            extra='''<Container ID="CCBModCheckBar" Anchor="L,T" Offset="14,410" Size="996,34">
              <Label ID="CCBModCheckSummary" Anchor="L,C" Size="795,28" Style="FontNormal12" String="LOC_CCBMC_NOT_CHECKED" />
              <GridButton ID="CCBModCheckButton" Anchor="R,C" Size="155,28" Style="ButtonControl" String="LOC_CCBMC_CHECK" />
            <Container ID="CCBModCheckReasonBox" Anchor="L,C" Size="810,30" Hidden="1">
              <Label ID="CCBModCheckReason" Anchor="L,C" Style="FontNormal12" WrapWidth="775" String="" />
              <Button ID="CCBModCheckReasonClose" Anchor="R,T" Size="28,28" Texture="Controls_CloseButtonAlt" />
            </Container>
            </Container>\n            '''
            assert s.count(marker)==1;s=s.replace(marker,extra+marker)
        else:
            marker='</ContextDefaults>';assert s.count(marker)==1
            extra='''<Container ID="CCBToolkitFooter" Anchor="R,B" Offset="14,35" Size="680,55">
              <Label ID="CCBToolkitVersion" Anchor="R,B" Offset="0,22" Style="FontNormal12" Align="Right" String="CCB" />
              <Label ID="CCBToolkitCoreHint" Anchor="R,B" Offset="0,0" Style="FontNormal12" Align="Right" WrapWidth="650" String="" />
            </Container>\n'''
            s=s.replace(marker,extra+marker)
        (OUT/name).write_text(s,encoding='utf-8',newline='\n')
    (ROOT/'tools/modcheck_frontend_baseline.json').write_text(json.dumps({'game':str(GAME),'sha256':hashes},indent=2),encoding='utf-8')
    print(json.dumps({'generated':list(inputs),'baseline':hashes},indent=2))
if __name__=='__main__':generate()
