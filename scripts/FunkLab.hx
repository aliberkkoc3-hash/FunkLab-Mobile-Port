package funkin.modding;

import flixel.FlxG;
import flixel.util.FlxColor;
import flixel.util.FlxTimer;
import haxe.ds.StringMap;
import funkin.Conductor;
import funkin.Highscore;
import funkin.play.PlayState;
import funkin.play.notes.NoteSprite;
import funkin.play.scoring.Scoring;
import funkin.modding.events.HitNoteScriptEvent;
import funkin.modding.events.ScriptEvent;
import funkin.modding.events.SongLoadScriptEvent;
import funkin.modding.module.Module;
import funkin.modding.module.ModuleHandler;
import funkin.util.Constants;
import funkin.util.ReflectUtil;
import funkin.save.Save;
import Reflect;

class FunkLab extends Module
{
    public static var isFunkLabActive:Bool = false;
    var didit:Bool = false;
    var lastBotText:String = null;
    var heldHoldDirections:StringMap;
    var lastDodgedHitTime:Float = -1;

    public static var ignoreKinds:Array<String>;

    public static var highlightDangerousNotes:Bool = false;
    var autoDodgeDangerousNotes:Bool = true;

    public function new()
    {
        super("FunkLabModule");
        isFunkLabActive = false;
        heldHoldDirections = new StringMap();
        ignoreKinds = [
            "hurt","trap","death","kill","deadly","bone","bluebone",
            "bluebounce","bone_blue","bone_death","fire","poison","fatal","ban",
            "glitch","gf glitch","bothsings","hurt note","death note","trap note",
            "hell","ex"
        ];
    }

    override function onSongLoaded(e:SongLoadScriptEvent):Void
    {
        if (Save.instance.modOptions.get("SuperBot") == null)
            Save.instance.modOptions.set("SuperBot", false);

        isFunkLabActive = Save.instance.modOptions.get("SuperBot");
        lastDodgedHitTime = -1;
        applySuperBotOptimizations();
    }

    function goodNoteHit(note:NoteSprite, state:PlayState):Void
    {
        if (note == null || note.noteData == null || state == null) return;
        if (note.hasBeenHit) return;

        var score = Scoring.scoreNote(0);
        var daRating = Scoring.judgeNote(0);
        var hitEvent = new HitNoteScriptEvent(note, Constants.HEALTH_SICK_BONUS, score, daRating, false, 0, 0, true);

        state.dispatchEvent(hitEvent);
        if (hitEvent.eventCanceled) return;

        Highscore.tallies.totalNotesHit++;
        Highscore.tallies.sickNotes++;

        var sl = state.playerStrumline;
        sl.hitNote(note);
        sl.noteVibrations.tryNoteVibration();

        if (note.holdNoteSprite != null)
        {
            if (sl.isPlayer)
                sl.pressKey(note.holdNoteSprite.noteDirection);
            sl.playNoteHoldCover(note.holdNoteSprite);
        }

        if (hitEvent.doesNotesplash && note.noteData != null)
            sl.playNoteSplash(note.noteData.getDirection());

        state.vocals.playerVolume = 1;
        state.applyScore(hitEvent.score, hitEvent.judgement, hitEvent.healthChange, hitEvent.isComboBreak);
        state.popUpScore(hitEvent.judgement);

        if (state.currentStage != null)
        {
            var player = state.currentStage.getPlayer();
            if (player != null)
                player.holdTimer = 0;
            state.currentStage.getGirlfriend()?.playComboAnimation(Highscore.tallies.combo);
        }
    }

    function handleAutoMiss(e:Dynamic):Void
    {
        if (!isFunkLabActive) return;
        if (e.note == null) return;
        if (isDangerous(e.note)) return;
        e.cancel();
        goodNoteHit(e.note, PlayState.instance);
    }

    function onNoteMiss(e:Dynamic):Void { handleAutoMiss(e); }

    function onNoteGhostMiss(e:Dynamic):Void
    {
        if (!isFunkLabActive) return;
        e.cancel();
    }

    function onNoteHoldDrop(e:Dynamic):Void { handleAutoMiss(e); }

    function isDangerous(n:NoteSprite):Bool
    {
        if (n == null) return false;
        if (n.kind == 'weekend-1-firegun') return false;

        var text = "";
        if (n.kind != null) text = Std.string(n.kind).toLowerCase();

        if (n.noteData != null && n.noteData.kind != null)
        {
            var noteDataKind = Std.string(n.noteData.kind).toLowerCase();
            if (noteDataKind != "")
                text += (text.length > 0 ? " " : "") + noteDataKind;
        }

        for (kw in ignoreKinds)
        {
            if (text.indexOf(kw) != -1)
            {
                if (highlightDangerousNotes && n.alive)
                {
                    n.color = FlxColor.RED;
                    n.alpha = 0.5;
                }
                return true;
            }
        }
        return false;
    }

    function detectDangerousNote(n:NoteSprite):Void
    {
        if (!autoDodgeDangerousNotes || n == null || !n.alive || n.hasBeenHit) return;
        if (!isDangerous(n)) return;

        if (highlightDangerousNotes)
        {
            n.color = FlxColor.RED;
            n.alpha = 0.5;
        }
    }

    function handleSawDodge():Void
    {
        var module = ModuleHandler.getModule("SawbladeAndDodgeModule");
        if (module == null) return;

        var activeEvent:Dynamic = module.scriptGet('activeEvent');
        var eventReady:Bool = module.scriptGet('eventReady') == true;
        var canDodge:Bool = module.scriptCall('canDodge') == true;

        if (activeEvent == null || !eventReady || !canDodge) return;

        var thisHitTime:Float = activeEvent.hitTime;
        if (thisHitTime == lastDodgedHitTime) return;

        if (Conductor.instance.songPosition >= thisHitTime)
        {
            lastDodgedHitTime = thisHitTime;
            module.scriptCall('bfDodge');
        }
    }

    override function onUpdate(e:ScriptEvent):Void
    {
        onUpdatePause();

        var s = PlayState.instance;
        if (!isFunkLabActive || s == null || s.isGamePaused || s.playerStrumline == null || s.startingSong || s.isInCutscene)
            return;

        handleSawDodge();

        var sl = s.playerStrumline;
        var c = Conductor.instance;

        var previousCombo = Highscore.tallies.combo;
        var previousMaxCombo = Highscore.tallies.maxCombo;
        var previousSicks = Highscore.tallies.sickNotes;
        var previousTotal = Highscore.tallies.totalNotesHit;

        for (n in sl.getNotesMayHit())
        {
            if (n == null || !n.alive || n.hasBeenHit) continue;

            if (isDangerous(n))
            {
                detectDangerousNote(n);
                continue;
            }

            if (c.songPosition >= n.strumTime)
                goodNoteHit(n, s);
        }

        for (n in sl.notes.members)
        {
            if (n == null || !n.alive || n.hasBeenHit) continue;
            if (isDangerous(n)) continue;

            if (c.songPosition >= n.strumTime)
                goodNoteHit(n, s);
        }

        for (h in sl.holdNotes.members)
        {
            if (h == null) continue;

            var holdKey = Std.string(h.noteDirection) + "_" + Std.string(h.strumTime);

            if (h.alive && h.hitNote && !h.missedNote)
            {
                if (s.currentStage != null && s.currentStage.getPlayer() != null && s.currentStage.getPlayer().isSinging())
                    s.currentStage.getPlayer().holdTimer = 0;

                if (h.sustainLength > 0 && sl.isPlayer)
                {
                    if (!heldHoldDirections.exists(holdKey))
                    {
                        sl.pressKey(h.noteDirection);
                        heldHoldDirections.set(holdKey, true);
                    }
                }
                else if (h.sustainLength <= 0 && sl.isPlayer && heldHoldDirections.exists(holdKey))
                {
                    sl.releaseKey(h.noteDirection);
                    heldHoldDirections.remove(holdKey);
                }
            }
            else if (heldHoldDirections.exists(holdKey))
            {
                sl.releaseKey(h.noteDirection);
                heldHoldDirections.remove(holdKey);
            }
        }

        for (holdKey in heldHoldDirections.keys())
        {
            var parts = holdKey.split("_");
            var dir = Std.parseInt(parts[0]);
            var stillActive = false;

            for (h in sl.holdNotes.members)
            {
                if (h != null && h.alive && h.hitNote && !h.missedNote && h.sustainLength > 0)
                {
                    var hKey = Std.string(h.noteDirection) + "_" + Std.string(h.strumTime);
                    if (hKey == holdKey)
                    {
                        stillActive = true;
                        break;
                    }
                }
            }

            if (!stillActive)
            {
                sl.releaseKey(dir);
                heldHoldDirections.remove(holdKey);
            }
        }

        if (Highscore.tallies.combo < previousCombo)
            Highscore.tallies.combo = previousCombo;
        if (Highscore.tallies.maxCombo < previousMaxCombo)
            Highscore.tallies.maxCombo = previousMaxCombo;
        if (Highscore.tallies.combo > Highscore.tallies.maxCombo)
            Highscore.tallies.maxCombo = Highscore.tallies.combo;
        if (Highscore.tallies.sickNotes < previousSicks)
            Highscore.tallies.sickNotes = previousSicks;
        if (Highscore.tallies.totalNotesHit < previousTotal)
            Highscore.tallies.totalNotesHit = previousTotal;
    }

    override function dispatchEvent(e:ScriptEvent):Void
    {
        var s = PlayState.instance;
        if (!isFunkLabActive || s == null || e == null) return;
        s.dispatchEvent(e);
    }

    function applySuperBotOptimizations():Void
    {
        if (!isFunkLabActive) return;

        var s = PlayState.instance;
        if (s == null) return;

        if (s.currentStage != null)
        {
            if (Reflect.hasField(s.currentStage, "fog"))
            {
                var fog = Reflect.field(s.currentStage, "fog");
                if (fog != null)
                {
                    fog.visible = false;
                    fog.active = false;
                }
            }

            if (Reflect.hasField(s.currentStage, "particles"))
            {
                var p = Reflect.field(s.currentStage, "particles");
                if (p != null)
                {
                    p.visible = false;
                    p.active = false;
                }
            }

            if (Reflect.hasField(s.currentStage, "script"))
            {
                var scr = Reflect.field(s.currentStage, "script");
                if (scr != null)
                    scr.active = false;
            }
        }
    }

    function onUpdatePause():Void
    {
        var substateClassName = ReflectUtil.getClassNameOf(FlxG.state.subState);

        if (substateClassName == null || substateClassName.indexOf("PauseSubState") == -1)
        {
            didit = false;
            return;
        }

        var pauseState:Dynamic = FlxG.state.subState;

        if (!didit)
        {
            didit = true;
            pauseState.persistentUpdate = false;
        }

        var menuEntries = pauseState.currentMenuEntries;
        var insertIndex = menuEntries.length > 2 ? menuEntries.length - 2 : menuEntries.length;

        var botText = "FunkLab: " + (isFunkLabActive ? "AKTIF" : "AKTIF DEGIL");
        var found = false;
        var changed = false;

        for (i in 0...menuEntries.length)
        {
            var e = menuEntries[i];
            if (e != null && e.text != null && e.text.indexOf("FunkLab:") == 0)
            {
                found = true;
                if (e.text != botText)
                {
                    e.text = botText;
                    changed = true;
                }
                break;
            }
        }

        var scrollPause = function(state:Dynamic)
        {
            if (FlxG.onMobile)
            {
                for (entry in state.currentMenuEntries)
                {
                    if (state.currentMenuEntries.length >= 6)
                        entry.sprite.y -= 105 * (state.currentMenuEntries.length == 6 ? 0.75 : 1);
                }
            }
        };

        if (!found)
        {
            menuEntries.insert(insertIndex, {
                text: botText,
                callback: function()
                {
                    isFunkLabActive = !isFunkLabActive;
                    Save.instance.modOptions.set("FunkLab", isFunkLabActive);
                    applySuperBotOptimizations();

                    for (j in 0...menuEntries.length)
                    {
                        var me = menuEntries[j];
                        if (me != null && me.text != null && me.text.indexOf("FunkLab:") == 0)
                        {
                            me.text = "FunkLab: " + (isFunkLabActive ? "on" : "off");
                            break;
                        }
                    }

                    pauseState.clearAndAddMenuEntries();
                    pauseState.changeSelection();
                    scrollPause(pauseState);
                }
            });

            changed = true;
        }

        if (changed || lastBotText == null)
        {
            lastBotText = botText;
            pauseState.clearAndAddMenuEntries();
            pauseState.changeSelection();
            scrollPause(pauseState);
        }
    }
}
