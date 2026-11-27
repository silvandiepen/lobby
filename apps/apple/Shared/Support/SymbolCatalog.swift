// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The symbols a manager picks an icon from, in groups, with the everyday words that find
/// each: English, then Dutch. One line per symbol: `name: words`.
///
/// All of them exist on the oldest system the apps run on (iOS 18, macOS 15, tvOS 18). Any
/// other symbol can be found by typing its exact name. None belongs to a category: the words
/// describe the picture, never a household's own names.
enum SymbolCatalog {
    struct Entry: Hashable, Sendable, Identifiable {
        let symbol: String
        /// Folded words, see `SymbolSearch.words(in:)`.
        let keywords: [String]
        var id: String { symbol }
    }

    struct Group: Sendable, Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let groups: [Group] = tables.map { title, table in
        Group(title: title, entries: table.split(separator: "\n").compactMap(entry).filter { AppSymbol.existing($0.symbol) != nil })
    }

    static let entries: [Entry] = groups.flatMap(\.entries)

    /// What VoiceOver says for a symbol: what it shows, with its own name to tell two apart.
    static func spokenName(of symbol: String) -> String {
        let name = symbol.replacingOccurrences(of: ".", with: " ")
        guard let word = keywordsBySymbol[symbol]?.first, !name.hasPrefix(word) else { return name }
        return "\(word), \(name)"
    }

    private static let keywordsBySymbol = Dictionary(uniqueKeysWithValues: entries.map { ($0.symbol, $0.keywords) })

    private static func entry(_ line: Substring) -> Entry? {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return Entry(symbol: String(parts[0]), keywords: SymbolSearch.words(in: String(parts[1])))
    }

    private static let tables: [(String, String)] = [
        ("Film and Television", """
            film.fill: film movie cinema reel movies films bioscoop speelfilm rolprent
            film.stack.fill: films collection movies stack verzameling filmreeks reeks saga
            movieclapper.fill: clapperboard movie director studio scene klapper regie filmstudio opname
            popcorn.fill: popcorn snack cinema movie night filmavond bioscoop
            tv.fill: television tv series show shows televisie serie programma
            tv.and.mediabox.fill: television mediabox streaming kastje televisie
            play.rectangle.fill: video play clip youtube filmpje afspelen
            play.rectangle.on.rectangle.fill: videos clips trailers filmpjes afleveringen episodes
            video.fill: video camera home recording filmen opname thuisvideo
            video.badge.plus: new video addition nieuw toevoegen
            camera.fill: camera photo photography foto fotografie
            web.camera.fill: webcam camera vlog livestream
            videoprojector.fill: projector beamer cinema film thuisbioscoop
            theatermasks.fill: drama theater theatre comedy acting play masks toneel komedie maskers musical acteren cabaret
            ticket.fill: ticket cinema admission show premiere kaartje toegang première
            4k.tv.fill: 4k television quality hd uhd kwaliteit
            sparkles.tv.fill: highlights television special best uitgelicht bijzonder
            play.tv.fill: series streaming play binge serie kijken
            photo.fill: photo picture image foto afbeelding plaatje
            photo.stack.fill: photos album pictures foto's album fotoboek
            tray.full.fill: inbox watchlist collection kijklijst lade
            eye.fill: eye watch seen look oog kijken gezien
            eyeglasses: glasses smart study bril slim
            megaphone.fill: announcement loud advertisement megafoon aankondiging reclame
            opticaldisc.fill: disc dvd bluray cd schijf
            recordingtape: tape vhs recording band cassette opname
            antenna.radiowaves.left.and.right: broadcast radio antenna talk uitzending zender antenne
            newspaper.fill: news newspaper journalism nieuws krant journalistiek actualiteit
            mic.fill: microphone podcast talk interview stand-up microfoon praatprogramma
            bubble.left.and.bubble.right.fill: talk conversation chat dialogue gesprek praten talkshow
            quote.bubble.fill: quote poetry speech citaat gedicht
            captions.bubble.fill: subtitles captions foreign ondertiteling ondertitels buitenlands
            rectangle.stack.fill: collection stack season box verzameling seizoen box
            square.stack.fill: collection stack layers verzameling stapel
            square.stack.3d.up.fill: layers collection stack stapel lagen
            list.star: favourites favorites list best lijst favorieten
            """),
        ("Children and Family", """
            figure.and.child.holdinghands: parent child kids children family ouder kind kinderen samen
            figure.2.and.child.holdinghands: family kids children parents familie gezin kinderen ouders
            figure.2.arms.open: together couple friends samen stel vrienden
            person.2.fill: people couple friends two mensen stel vrienden
            person.3.fill: group people family team groep mensen familie ensemble
            person.fill: person one portrait biography persoon biografie portret
            person.crop.circle.fill: viewer person profile biography kijker profiel
            figure.child: child kid kids toddler children kind kleuter kinderen
            stroller.fill: baby stroller infant newborn kinderwagen baby
            teddybear.fill: teddy toys kids children bear baby toddler knuffel beer speelgoed kinderen peuter
            balloon.fill: balloon party birthday kids ballon feest verjaardag
            balloon.2.fill: balloons party birthday celebration ballonnen feest verjaardag kinderfeest
            birthday.cake.fill: birthday cake party celebration verjaardag taart feest
            gift.fill: gift present christmas birthday surprise cadeau kerst sinterklaas verjaardag verrassing
            party.popper.fill: party celebration newyear feest viering nieuwjaar oudjaar
            face.smiling.fill: smile happy funny comedy fun lach vrolijk grappig komedie humor
            face.dashed.fill: invisible mask mystery onzichtbaar masker
            puzzlepiece.fill: puzzle game toys kids puzzel spel speelgoed
            puzzlepiece.extension.fill: puzzle toys game puzzel bouwen
            paintpalette.fill: animation cartoon art paint drawing animatie tekenfilm tekenen kunst verf kleuren schilderen
            paintbrush.fill: paint art animation drawing schilderen verf kwast animatie
            paintbrush.pointed.fill: paint art brush illustration penseel schilderen illustratie
            pencil.and.scribble: drawing cartoon sketch animation tekenen tekenfilm schets krabbel
            scribble.variable: scribble drawing doodle krabbel tekening
            pencil: pencil write draw potlood schrijven tekenen
            wand.and.stars: magic fantasy fairytale wizard magie toveren sprookje tovenaar sprookjes fantasie
            wand.and.rays: magic wand wizard toverstaf magie tovenaar
            crown.fill: crown royal king queen princess prince kroon koning koningin prinses prins koninklijk
            backpack.fill: school backpack adventure rugzak school avontuur
            graduationcap.fill: school education learning study graduation onderwijs leren studie educatief
            studentdesk: school classroom desk klas schoolbank
            abc: abc letters alphabet learn alfabet leren lezen
            textformat.123: numbers counting math learn cijfers tellen rekenen
            lightbulb.fill: idea learning smart light lamp idee leren slim uitvinding
            bed.double.fill: bed sleep bedtime night slapen bedtijd nacht
            moon.zzz.fill: sleep bedtime night dream slapen bedtijd droom welterusten
            house.fill: home house family huis thuis gezin
            house.lodge.fill: cabin lodge mountain holiday hut chalet vakantie
            figure.play: play jump fun spelen springen plezier
            figure.run: run action chase sport rennen actie achtervolging
            """),
        ("Genres and Moods", """
            heart.fill: heart love romance romantic favourite hart liefde romantiek romantisch favoriet
            heart.circle.fill: romance love valentine liefde romantiek valentijn
            heart.slash.fill: heartbreak breakup drama sad liefdesverdriet verdrietig
            heart.text.square.fill: diary drama love story dagboek liefdesverhaal
            bolt.fill: action lightning power energy actie bliksem kracht energie spanning
            bolt.shield.fill: hero superhero power shield held superheld superhelden schild
            flame.fill: fire hot action popular vuur heet actie populair vlam
            burst.fill: explosion action bang explosie actie knal
            exclamationmark.triangle.fill: danger thriller warning suspense gevaar spanning waarschuwing
            theatermask.and.paintbrush.fill: arts theatre culture costume kunst cultuur toneel kostuum
            shield.fill: shield protect hero police schild beschermen politie held
            shield.lefthalf.filled: knight shield medieval defence ridder schild middeleeuwen
            figure.fencing: fencing sword knight swashbuckler pirate duel zwaard ridder schermen piraat piraten
            figure.martial.arts: martial arts karate kungfu fight vechtkunst vechten judo
            figure.boxing: boxing fight sport boksen vechten
            figure.archery: archery bow arrow robinhood boogschieten pijl boog
            scope: target spy sniper thriller doelwit spion vizier
            target: target aim doel mikken
            magnifyingglass: magnifier detective mystery crime search investigation zoeken speurder raadsel onderzoek mysterie misdaad vergrootglas
            lock.fill: crime prison secret locked slot geheim gevangenis misdaad
            key.fill: key secret mystery sleutel geheim mysterie
            key.horizontal.fill: key secret heist sleutel geheim roof
            building.columns.fill: history politics museum bank court geschiedenis politiek rechtbank oudheid klassiek
            scroll.fill: history epic legend old geschiedenis legende oud perkament
            hourglass: time history old waiting tijd geschiedenis zandloper
            clock.fill: time recent later clock tijd klok straks
            clock.arrow.circlepath: past history classic replay verleden klassiekers vroeger nostalgie
            calendar: calendar year seasonal date kalender jaar seizoen datum
            flag.fill: war politics country race oorlog politiek vlag land
            flag.checkered: race racing finish cars racen finish autosport
            medal.fill: medal war military award medaille oorlog militair prijs
            airplane.departure: travel holiday departure reizen vakantie vertrek
            moon.fill: night dark moon nacht donker maan
            moon.stars.fill: night dream fantasy moon evening nacht droom avond maan sterren
            moon.haze.fill: spooky horror night fog griezel eng mist halloween nacht griezelfilm
            eye.trianglebadge.exclamationmark.fill: scary thriller watch eng spannend
            ant.fill: insects horror bugs mier insecten kriebel
            brain.fill: mind thriller psychology thinking psychologie brein denken hersenen
            brain.head.profile.fill: psychology mind thinking psychologie denken brein
            sparkles: magic fantasy new special sparkle magie fantasie nieuw bijzonder glitter sprookje
            star.fill: star favourite best famous ster favoriet beste beroemd
            star.circle.fill: star best top ster beste topfilm
            star.square.on.square.fill: classics best collection klassiekers beste
            trophy.fill: award winner oscar sport best prijs winnaar beker award
            rosette: award prize winner rozet prijs winnaar
            hand.thumbsup.fill: like recommended good tip aanrader duim goed leuk
            face.smiling.inverse: comedy smile funny humor komedie lachen
            hands.clap.fill: applause show performance applaus voorstelling
            questionmark.circle.fill: quiz mystery unknown question vraag raadsel onbekend kwis
            infinity: endless forever loop oneindig eeuwig
            peacesign: peace hippie sixties vrede zestig
            drop.fill: drop blood water horror druppel bloed
            bandage.fill: hospital medical hurt pleister ziekenhuis medisch
            cross.case.fill: hospital doctor medical ziekenhuis dokter medisch arts
            stethoscope: doctor hospital medical dokter ziekenhuis arts medisch
            cross.fill: medical hospital religion kruis religie medisch
            briefcase.fill: work office business lawyer werk kantoor zaken advocaat
            person.badge.shield.checkmark.fill: police security guard politie beveiliging agent
            hammer.fill: building crafts diy work klussen bouwen gereedschap hamer
            wrench.and.screwdriver.fill: diy repair technology klussen reparatie techniek gereedschap
            """),
        ("Music and Sound", """
            music.note: music song melody muziek lied liedje
            music.note.list: music playlist songs musical soundtrack muziek afspeellijst liedjes
            music.quarternote.3: music song musical muziek noten
            music.mic: singing karaoke concert musical zingen concert zanger
            music.note.tv.fill: musicvideo concert music clip muziek muziekvideo
            music.note.house.fill: music home concert muziek huiskamer
            guitars.fill: guitar rock band concert music gitaar rock muziek
            pianokeys: piano classical music klassiek muziek toetsen
            pianokeys.inverse: piano jazz classical music klassiek muziek
            headphones: headphones listening audiobook music koptelefoon luisteren luisterboek
            hifispeaker.fill: speaker sound music luidspreker geluid muziek
            radio.fill: radio sound listening radio luisteren
            metronome.fill: metronome rhythm music ritme muziek
            tuningfork: tuning sound music stemvork klank
            waveform: sound wave audio geluid golf audio
            speaker.wave.3.fill: loud sound audio geluid hard luid
            figure.dance: dance dancing musical ballet dans dansen ballet
            figure.socialdance: dance ballroom couple stijldansen dansen
            dot.radiowaves.left.and.right: live broadcast podcast uitzending live
            bell.fill: bell alarm christmas notification bel klok kerst
            """),
        ("Animals", """
            pawprint.fill: animal animals pets paw dog cat nature dier dieren huisdier huisdieren poot
            dog.fill: dog puppy animals pets hond puppy dieren
            cat.fill: cat kitten animals pets kat poes dieren
            hare.fill: rabbit hare bunny fast easter konijn haas snel pasen
            tortoise.fill: turtle tortoise slow schildpad langzaam
            bird.fill: bird birds flying nature vogel vogels vliegen
            fish.fill: fish sea ocean underwater vis vissen zee oceaan onderwater
            lizard.fill: lizard reptile dinosaur dragon hagedis reptiel dinosaurus draak
            fossil.shell.fill: fossil prehistory dinosaur shell fossiel prehistorie dinosaurus dinosauriërs schelp
            ladybug.fill: ladybug insect bugs lieveheersbeestje insect beestjes
            teddybear: bear toy beer knuffel
            figure.equestrian.sports: horse riding western paard paarden paardrijden cowboy western
            """),
        ("Nature and Seasons", """
            leaf.fill: leaf nature green autumn plant blad natuur groen herfst
            tree.fill: tree forest nature wood boom bos natuur
            camera.macro: flower nature garden spring bloem natuur tuin lente
            laurel.leading: laurel award festival lauwerkrans prijs festival
            mountain.2.fill: mountain mountains adventure nature hiking berg bergen avontuur natuur wandelen
            water.waves: sea ocean water waves beach zee oceaan golven strand
            drop.circle.fill: water rain drop water regen
            sun.max.fill: sun summer day light zon zomer dag
            sun.horizon.fill: sunset western evening summer zonsondergang avond western
            sunrise.fill: sunrise morning ochtend zonsopgang
            sunset.fill: sunset evening western avond zonsondergang
            cloud.fill: cloud weather sky wolk weer lucht
            cloud.rain.fill: rain weather sad regen weer verdrietig
            cloud.bolt.fill: storm thunder disaster onweer storm ramp rampenfilm
            cloud.bolt.rain.fill: storm thunder disaster onweer storm ramp
            cloud.snow.fill: snow winter christmas sneeuw winter kerst
            cloud.fog.fill: fog mystery noir mist
            snowflake: snow winter christmas ice cold sneeuw winter kerst ijs kou kerstfilm
            snowflake.circle.fill: winter cold snow winter kou sneeuw
            wind: wind storm air wind lucht
            tornado: tornado storm disaster ramp wervelwind storm rampenfilm
            hurricane: hurricane storm disaster orkaan storm ramp
            rainbow: rainbow colour pride kids regenboog kleuren
            thermometer.sun.fill: hot summer heat heet zomer hitte
            umbrella.fill: rain umbrella paraplu regen
            beach.umbrella.fill: beach summer holiday strand zomer vakantie parasol
            carrot.fill: vegetable garden food wortel groente moestuin
            globe.europe.africa.fill: world earth documentary travel international wereld aarde documentaire reizen internationaal
            globe.americas.fill: world america earth wereld amerika aarde
            globe.asia.australia.fill: world asia anime earth wereld azië aarde
            globe: world international foreign language wereld internationaal buitenlands taal
            globe.desk.fill: geography world documentary aardrijkskunde wereld documentaire
            binoculars.fill: documentary discover nature spy verrekijker documentaire ontdekken natuur
            """),
        ("Science and Space", """
            atom: science physics scifi fiction sci-fi wetenschap natuurkunde sciencefiction
            flask.fill: science laboratory experiment wetenschap laboratorium proef experiment
            testtube.2: science laboratory experiment wetenschap laboratorium proefjes
            microbe.fill: virus bacteria pandemic science virus bacterie pandemie
            allergens.fill: virus spores science virus
            staroflife.fill: medical ambulance rescue medisch ambulance redding
            moon.circle.fill: space moon night ruimte maan
            circle.hexagongrid.fill: science pattern structure wetenschap patroon
            hexagon.fill: hexagon shape zeshoek vorm
            cube.fill: cube block 3d kubus blok
            cpu.fill: computer technology robot chip scifi technologie robot toekomst
            memorychip.fill: technology computer chip technologie computer
            desktopcomputer: computer technology hacker technologie computer
            laptopcomputer: laptop computer work laptop werk
            network: network technology internet netwerk technologie
            antenna.radiowaves.left.and.right.circle.fill: signal space alien broadcast signaal ruimte buitenaards
            sparkle: star space shine scifi fiction ster ruimte glans sciencefiction
            sun.dust.fill: space sun desert ruimte woestijn zon
            moonphase.waning.crescent: moon space night maan ruimte nacht
            circle.dotted.circle.fill: planet orbit space planeet baan ruimte
            circle.circle.fill: planet target space planeet ruimte
            move.3d: dimension space 3d dimensie ruimte
            rotate.3d.fill: dimension future 3d dimensie toekomst
            gyroscope: gyroscope space machine ruimte machine
            gearshape.fill: machine technology settings steampunk machine techniek tandwiel
            gearshape.2.fill: machine engineering technology techniek machines tandwielen
            ear.fill: ear alien listen oor luisteren
            waveform.path.ecg: medical hospital heartbeat medisch ziekenhuis hartslag
            function: mathematics science wiskunde wetenschap
            x.squareroot: mathematics school wiskunde school
            """),
        ("Travel and Places", """
            airplane: airplane travel flying holiday vliegtuig reizen vliegen vakantie luchtvaart
            car.fill: car road cars driving auto auto's rijden weg
            car.2.fill: cars traffic race auto's verkeer race
            bus.fill: bus travel bus reizen
            tram.fill: tram train city tram trein stad
            train.side.front.car: train railway travel trein spoor reizen
            bicycle: bicycle cycling fiets fietsen wielrennen
            motorcycle.fill: motorcycle biker road motor motorrijder
            scooter: scooter step
            sailboat.fill: boat sailing sea pirate boot zeilen zee piraat piraten
            ferry.fill: ship boat sea schip boot zee
            fuelpump.fill: petrol road cars benzine tankstation
            truck.box.fill: truck transport vrachtwagen transport
            map.fill: map adventure travel treasure kaart avontuur reizen schat landkaart
            mappin.and.ellipse: place location local plaats locatie lokaal
            location.fill: place direction locatie richting
            location.north.circle.fill: compass discover travel adventure kompas ontdekken reizen avontuur
            signpost.right.fill: sign road travel direction wegwijzer route reizen
            road.lanes: road roadtrip travel weg roadtrip
            tent.fill: camping adventure summer outdoors tent kamperen avontuur zomer buiten
            tent.2.fill: camping western circus kamperen kamp circus
            suitcase.fill: suitcase travel holiday koffer reizen vakantie
            suitcase.rolling.fill: suitcase holiday travel koffer vakantie reizen
            building.2.fill: city buildings urban stad gebouwen
            building.fill: building office hotel gebouw kantoor flat
            house.and.flag.fill: village home neighbourhood dorp huis buurt
            storefront.fill: shop store winkel
            signpost.right.and.left.fill: choice road travel keuze weg kruispunt
            tortoise.circle.fill: slow calm langzaam rustig
            lightrail.fill: train metro city trein metro stad
            cablecar.fill: cablecar mountains winter kabelbaan bergen
            figure.hiking: hiking adventure outdoors wandelen avontuur buiten
            figure.climbing: climbing adventure mountains klimmen avontuur bergen
            figure.sailing: sailing sea zeilen zee
            figure.open.water.swim: swimming water sea zwemmen zee
            figure.walk: walking journey lopen wandeling
            """),
        ("Sport and Games", """
            soccerball: football soccer sport voetbal sport
            basketball.fill: basketball sport basketbal sport
            football.fill: american football rugby sport
            baseball.fill: baseball sport honkbal sport
            tennis.racket: tennis sport tennis racket
            tennisball.fill: tennis ball sport tennisbal
            volleyball.fill: volleyball beach sport volleybal
            hockey.puck.fill: hockey ice sport ijshockey
            figure.skiing.downhill: skiing winter sport skiën wintersport
            figure.skating: skating ice winter schaatsen ijs
            figure.surfing: surfing beach sea surfen strand zee
            figure.skateboarding: skateboard city skaten skateboarden
            figure.pool.swim: swimming sport pool zwemmen zwembad
            figure.outdoor.cycle: cycling bike sport wielrennen fietsen
            figure.gymnastics: gymnastics sport turnen gymnastiek
            figure.indoor.soccer: football soccer sport voetbal voetballen
            figure.yoga: yoga exercise calm yoga rust ontspanning
            figure.mind.and.body: yoga meditation calm meditatie rust ontspanning
            figure.golf: golf sport golfen
            sportscourt.fill: sport stadium match stadion wedstrijd
            dumbbell.fill: fitness training sport gym sportschool trainen
            gamecontroller.fill: game gaming play videogame spel gamen spelen
            arcade.stick.console.fill: arcade game retro spelletjes retro
            dice.fill: game dice luck spel dobbelsteen geluk spelletjes
            die.face.5.fill: game dice luck dobbelsteen spel
            suit.spade.fill: cards casino poker kaarten casino
            suit.club.fill: cards casino poker kaarten
            suit.diamond.fill: diamond cards casino diamant kaarten ruit
            suit.heart.fill: heart cards love hart kaarten liefde
            checkerboard.rectangle: chess checkers game schaken dammen bord
            """),
        ("Home, Food and Life", """
            fork.knife: food cooking restaurant eten koken restaurant
            cup.and.saucer.fill: coffee tea cosy koffie thee gezellig
            mug.fill: mug coffee beer mok koffie bier
            wineglass.fill: wine dinner evening wijn diner avond
            takeoutbag.and.cup.and.straw.fill: fastfood snack eten afhaal
            frying.pan.fill: cooking kitchen food koken keuken pan bakken
            oven.fill: baking kitchen oven bakken keuken
            refrigerator.fill: kitchen fridge koelkast keuken
            sofa.fill: sofa living couch home bank woonkamer huiskamer thuis
            chair.lounge.fill: lounge relax chair ontspannen stoel luieren
            lamp.table.fill: lamp evening cosy lamp avond gezellig
            fireplace.fill: fireplace cosy winter christmas haard gezellig winter kerst
            bathtub.fill: bath bathroom bad badkamer
            door.left.hand.open: door new open deur nieuw
            books.vertical.fill: books library reading history boeken bibliotheek lezen
            book.fill: book story reading literature boek verhaal lezen literatuur
            book.closed.fill: book novel literature story boek roman verhaal
            book.pages.fill: book story biography boek verhaal biografie
            text.book.closed.fill: book study learning boek studie leren
            magazine.fill: magazine fashion tijdschrift mode
            bookmark.fill: bookmark saved later bladwijzer bewaard later
            envelope.fill: letter mail post brief post
            cart.fill: cart shopping winkelen boodschappen
            bag.fill: bag shopping fashion tas winkelen mode
            handbag.fill: handbag fashion handtas mode
            tshirt.fill: fashion clothes kleding mode
            shoe.fill: shoes fashion sport schoenen
            hat.widebrim.fill: hat western cowboy detective hoed cowboy western
            hanger: hanger fashion clothes kleding mode kleerhanger
            comb.fill: beauty hair kapper haar
            eyebrow: eyebrow beauty face schoonheid
            mustache.fill: moustache funny detective snor grappig
            mouth.fill: mouth talk kiss mond praten kus
            scissors: crafts cut schaar knutselen knippen
            creditcard.fill: money shopping geld betalen
            banknote.fill: money heist business geld roof
            eurosign.circle.fill: money euro business geld
            dollarsign.circle.fill: money crime business geld
            phone.fill: phone call telefoon bellen
            alarm.fill: alarm morning time wekker ochtend
            deskclock.fill: clock time evening klok tijd
            washer.fill: laundry home was wasmachine
            pills.fill: medicine medical medicijnen
            heart.text.clipboard.fill: health medical gezondheid medisch
            hand.raised.fill: stop parental warning stop hand
            hand.wave.fill: hello welcome hallo welkom zwaaien
            accessibility: access inclusive toegankelijk
            figure.2: couple friends two stel vrienden
            figure.stand: person one persoon
            figure.wave: hello person hallo
            """),
        ("Shapes and Labels", """
            folder.fill: folder category map categorie
            tag.fill: tag genre label etiket
            archivebox.fill: archive old storage archief oud bewaren
            shippingbox.fill: box new package doos nieuw pakket
            tray.fill: tray inbox bak
            externaldrive.fill: drive storage disk schijf opslag
            circle.fill: circle round cirkel rond
            square.fill: square vierkant
            triangle.fill: triangle driehoek
            diamond.fill: diamond ruit
            seal.fill: seal badge zegel
            checkmark.seal.fill: approved verified goedgekeurd
            checkmark.circle.fill: done seen finished klaar gezien af
            plus.circle.fill: plus more extra meer
            number: number cijfer nummer
            at: at internet
            asterisk: asterisk special bijzonder
            exclamationmark.circle.fill: important attention belangrijk
            info.circle.fill: information documentary informatie documentaire
            pin.fill: pin keep vastzetten bewaren
            paperclip: clip attachment paperclip
            link: link connection verbinding
            square.grid.2x2.fill: grid all overview alles overzicht
            circle.grid.3x3.fill: grid pattern patroon
            circle.lefthalf.filled: contrast blackandwhite noir zwartwit
            circle.righthalf.filled: contrast classic noir zwartwit klassiek
            swatchpalette.fill: colours palette design kleuren ontwerp
            lightspectrum.horizontal: spectrum rainbow colours regenboog kleuren
            aqi.medium: dots pattern stippen patroon
            wineglass: wine glass wijn
            arrow.down.circle.fill: download downloads ophalen
            arrow.triangle.2.circlepath: repeat again herhaling opnieuw
            shuffle: shuffle random mix willekeurig mix
            gauge.with.dots.needle.67percent: speed fast snelheid snel
            slider.horizontal.3: choices settings keuzes instellingen
            person.fill.questionmark: mystery unknown whodunit mysterie onbekend dader
            18.circle.fill: adult grownup volwassen volwassenen
            16.circle.fill: teen tiener tieners
            12.circle.fill: kids twelve twaalf
            6.circle.fill: kids six zes
            """),
    ]
}
