module App exposing (..)

import Api
import Browser
import Browser.Navigation as Nav
import CodebaseTree
import Definition.Reference exposing (Reference)
import Env exposing (AppContext(..), Env, OperatingSystem(..))
import Finder
import Finder.SearchOptions as SearchOptions
import FullyQualifiedName as FQN exposing (FQN)
import Html exposing (Html, a, div, h1, h2, h3, header, nav, p, section, span, strong, text)
import Html.Attributes exposing (class, classList, href, id, rel, target, title)
import Html.Events exposing (onClick)
import Http
import KeyboardShortcut
import KeyboardShortcut.Key as Key exposing (Key(..))
import KeyboardShortcut.KeyboardEvent as KeyboardEvent exposing (KeyboardEvent)
import Namespace exposing (NamespaceDetails)
import Perspective exposing (Perspective(..))
import PerspectiveLanding
import RemoteData
import Route exposing (Route)
import UI
import UI.AppHeader as AppHeader
import UI.Banner as Banner
import UI.Button as Button
import UI.Icon as Icon
import UI.Modal as Modal
import UI.Sidebar as Sidebar
import UI.Tooltip as Tooltip
import UnisonShare.SidebarContent
import Url exposing (Url)
import Workspace



-- MODEL


type Modal
    = NoModal
    | FinderModal Finder.Model
    | HelpModal
    | ReportBugModal
    | PublishModal


type alias Model =
    { navKey : Nav.Key
    , route : Route
    , codebaseTree : CodebaseTree.Model
    , workspace : Workspace.Model
    , perspectiveLanding : PerspectiveLanding.Model
    , modal : Modal
    , keyboardShortcut : KeyboardShortcut.Model
    , env : Env

    -- This is called "toggled" and not "hidden" because the behavior of
    -- toggling the sidebar on/off is inverse on mobile vs desktop
    , sidebarToggled : Bool
    }


init : Env -> Route -> Nav.Key -> ( Model, Cmd Msg )
init env route navKey =
    let
        ( workspace, workspaceCmd ) =
            case route of
                Route.Definition _ ref ->
                    Workspace.init env (Just ref)

                _ ->
                    Workspace.init env Nothing

        ( codebaseTree, codebaseTreeCmd ) =
            CodebaseTree.init env

        fetchNamespaceDetailsCmd =
            env.perspective
                |> fetchNamespaceDetails
                |> Maybe.map (Api.perform env.apiBasePath)
                |> Maybe.withDefault Cmd.none

        model =
            { navKey = navKey
            , route = route
            , workspace = workspace
            , perspectiveLanding = PerspectiveLanding.init
            , codebaseTree = codebaseTree
            , modal = NoModal
            , keyboardShortcut = KeyboardShortcut.init env.operatingSystem
            , env = env
            , sidebarToggled = False
            }
    in
    ( model
    , Cmd.batch
        [ Cmd.map CodebaseTreeMsg codebaseTreeCmd
        , Cmd.map WorkspaceMsg workspaceCmd
        , fetchNamespaceDetailsCmd
        ]
    )



-- UPDATE


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | ChangePerspective Perspective
    | FetchPerspectiveNamespaceDetailsFinished FQN (Result Http.Error NamespaceDetails)
    | Keydown KeyboardEvent
    | OpenDefinition Reference
    | ShowModal Modal
    | CloseModal
    | ToggleSidebar
      -- sub msgs
    | FinderMsg Finder.Msg
    | WorkspaceMsg Workspace.Msg
    | PerspectiveLandingMsg PerspectiveLanding.Msg
    | CodebaseTreeMsg CodebaseTree.Msg
    | KeyboardShortcutMsg KeyboardShortcut.Msg


update : Msg -> Model -> ( Model, Cmd Msg )
update msg ({ env } as model) =
    case msg of
        LinkClicked _ ->
            ( model, Cmd.none )

        UrlChanged url ->
            -- URL changes happen when setting focus on a definitions.
            -- Currently, the URL change is a result of that as oppose to focus
            -- being a result of a URL change
            ( { model | route = Route.fromUrl env.basePath url }, Cmd.none )

        ChangePerspective perspective ->
            replacePerspective model perspective

        FetchPerspectiveNamespaceDetailsFinished fqn details ->
            let
                perspective =
                    case env.perspective of
                        Namespace p ->
                            if FQN.equals p.fqn fqn then
                                Namespace { p | details = RemoteData.fromResult details }

                            else
                                env.perspective

                        _ ->
                            env.perspective

                nextEnv =
                    { env | perspective = perspective }
            in
            ( { model | env = nextEnv }, Cmd.none )

        Keydown event ->
            keydown model event

        OpenDefinition ref ->
            openDefinition model ref

        ShowModal modal ->
            ( { model | modal = modal }, Cmd.none )

        CloseModal ->
            ( { model | modal = NoModal }, Cmd.none )

        ToggleSidebar ->
            ( { model | sidebarToggled = not model.sidebarToggled }, Cmd.none )

        -- Sub msgs
        WorkspaceMsg wMsg ->
            let
                ( workspace, wCmd, outMsg ) =
                    Workspace.update env wMsg model.workspace

                model2 =
                    { model | workspace = workspace }

                ( model3, cmd ) =
                    handleWorkspaceOutMsg model2 outMsg
            in
            ( model3, Cmd.batch [ cmd, Cmd.map WorkspaceMsg wCmd ] )

        PerspectiveLandingMsg rMsg ->
            let
                ( perspectiveLanding, outMsg ) =
                    PerspectiveLanding.update rMsg model.perspectiveLanding

                model2 =
                    { model | perspectiveLanding = perspectiveLanding }
            in
            case outMsg of
                PerspectiveLanding.OpenDefinition ref ->
                    openDefinition model2 ref

                PerspectiveLanding.ShowFinderRequest ->
                    showFinder model2 Nothing

                PerspectiveLanding.None ->
                    ( model2, Cmd.none )

        CodebaseTreeMsg cMsg ->
            let
                ( codebaseTree, cCmd, outMsg ) =
                    CodebaseTree.update env cMsg model.codebaseTree

                model2 =
                    { model | codebaseTree = codebaseTree }

                ( model3, cmd ) =
                    case outMsg of
                        CodebaseTree.None ->
                            ( model2, Cmd.none )

                        CodebaseTree.OpenDefinition ref ->
                            -- reset sidebarToggled to close it on mobile, but keep it open on desktop
                            let
                                model4 =
                                    { model2 | sidebarToggled = False }
                            in
                            openDefinition model4 ref

                        CodebaseTree.ChangePerspectiveToNamespace fqn ->
                            fqn
                                |> Perspective.toNamespacePerspective model.env.perspective
                                |> replacePerspective model
            in
            ( model3, Cmd.batch [ cmd, Cmd.map CodebaseTreeMsg cCmd ] )

        FinderMsg fMsg ->
            case model.modal of
                FinderModal fModel ->
                    let
                        ( fm, fc, out ) =
                            Finder.update env fMsg fModel
                    in
                    case out of
                        Finder.Remain ->
                            ( { model | modal = FinderModal fm }, Cmd.map FinderMsg fc )

                        Finder.Exit ->
                            ( { model | modal = NoModal }, Cmd.none )

                        Finder.OpenDefinition ref ->
                            openDefinition { model | modal = NoModal } ref

                _ ->
                    ( model, Cmd.none )

        KeyboardShortcutMsg kMsg ->
            let
                ( keyboardShortcut, cmd ) =
                    KeyboardShortcut.update kMsg model.keyboardShortcut
            in
            ( { model | keyboardShortcut = keyboardShortcut }, Cmd.map KeyboardShortcutMsg cmd )



-- UPDATE HELPERS


openDefinition : Model -> Reference -> ( Model, Cmd Msg )
openDefinition model ref =
    let
        ( workspace, wCmd, outMsg ) =
            Workspace.open model.env model.workspace ref

        model2 =
            { model | workspace = workspace }

        ( model3, cmd ) =
            handleWorkspaceOutMsg model2 outMsg
    in
    ( model3, Cmd.batch [ cmd, Cmd.map WorkspaceMsg wCmd ] )


replacePerspective : Model -> Perspective -> ( Model, Cmd Msg )
replacePerspective ({ env } as model) perspective =
    let
        newEnv =
            { env | perspective = perspective }

        ( codebaseTree, codebaseTreeCmd ) =
            CodebaseTree.init newEnv

        changeRouteCmd =
            Route.replacePerspective model.navKey (Perspective.toParams perspective) model.route

        fetchNamespaceDetailsCmd =
            perspective
                |> fetchNamespaceDetails
                |> Maybe.map (Api.perform env.apiBasePath)
                |> Maybe.withDefault Cmd.none
    in
    ( { model | env = newEnv, codebaseTree = codebaseTree }
    , Cmd.batch
        [ Cmd.map CodebaseTreeMsg codebaseTreeCmd
        , changeRouteCmd
        , fetchNamespaceDetailsCmd
        ]
    )


handleWorkspaceOutMsg : Model -> Workspace.OutMsg -> ( Model, Cmd Msg )
handleWorkspaceOutMsg model out =
    case out of
        Workspace.None ->
            ( model, Cmd.none )

        Workspace.ShowFinderRequest withinNamespace ->
            showFinder model withinNamespace

        Workspace.Focused ref ->
            ( model, Route.navigateToByReference model.navKey model.route ref )

        Workspace.Emptied ->
            ( model, Route.navigateToCurrentPerspective model.navKey model.route )

        Workspace.ChangePerspectiveToNamespace fqn ->
            fqn
                |> Perspective.toNamespacePerspective model.env.perspective
                |> replacePerspective model


keydown : Model -> KeyboardEvent -> ( Model, Cmd Msg )
keydown model keyboardEvent =
    let
        shortcut =
            KeyboardShortcut.fromKeyboardEvent model.keyboardShortcut keyboardEvent

        noOp =
            ( model, Cmd.none )
    in
    case shortcut of
        KeyboardShortcut.Chord Ctrl (K _) ->
            showFinder model Nothing

        KeyboardShortcut.Chord Meta (K _) ->
            if model.env.operatingSystem == Env.MacOS then
                showFinder model Nothing

            else
                noOp

        KeyboardShortcut.Sequence _ ForwardSlash ->
            showFinder model Nothing

        KeyboardShortcut.Chord Shift QuestionMark ->
            ( { model | modal = HelpModal }, Cmd.none )

        KeyboardShortcut.Sequence _ Escape ->
            if model.modal == HelpModal then
                ( { model | modal = NoModal }, Cmd.none )

            else
                noOp

        _ ->
            noOp


showFinder :
    { m | env : Env, modal : Modal }
    -> Maybe FQN
    -> ( { m | env : Env, modal : Modal }, Cmd Msg )
showFinder model withinNamespace =
    let
        options =
            SearchOptions.init model.env.perspective withinNamespace

        ( fm, fcmd ) =
            Finder.init model.env options
    in
    ( { model | modal = FinderModal fm }, Cmd.map FinderMsg fcmd )



-- EFFECTS


fetchNamespaceDetails : Perspective -> Maybe (Api.ApiRequest NamespaceDetails Msg)
fetchNamespaceDetails perspective =
    case perspective of
        Namespace { fqn } ->
            fqn
                |> Api.namespace perspective
                |> Api.toRequest Namespace.decodeDetails (FetchPerspectiveNamespaceDetailsFinished fqn)
                |> Just

        _ ->
            Nothing



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ KeyboardEvent.subscribe KeyboardEvent.Keydown Keydown
        , Sub.map WorkspaceMsg (Workspace.subscriptions model.workspace)
        ]



-- VIEW


appTitle : Maybe msg -> AppContext -> AppHeader.AppTitle msg
appTitle clickMsg appContext =
    let
        appTitle_ =
            case clickMsg of
                Nothing ->
                    AppHeader.Disabled

                Just msg ->
                    AppHeader.Clickable msg

        content =
            case appContext of
                Env.Ucm ->
                    h1 [] [ text "Unison", span [ class "context ucm" ] [ text "Local" ] ]

                Env.UnisonShare ->
                    h1 [] [ text "Unison", span [ class "context unison-share" ] [ text "Share" ] ]
    in
    appTitle_ content


viewAppHeader : Model -> Html Msg
viewAppHeader model =
    let
        { appContext, perspective } =
            model.env

        changePerspectiveMsg =
            case perspective of
                Codebase codebaseHash ->
                    ChangePerspective (Codebase codebaseHash)

                Namespace { codebaseHash } ->
                    ChangePerspective (Codebase codebaseHash)

        appTitle_ =
            appTitle (Just changePerspectiveMsg) appContext

        banner =
            case appContext of
                Env.Ucm ->
                    Nothing

                Env.UnisonShare ->
                    Just
                        (Banner.promotion
                            "hacktoberfest"
                            "🎃 Unison is participating in #Hacktoberfest: contribute and get rewards!"
                            (ChangePerspective (Perspective.toNamespacePerspective perspective (FQN.fromString "unison.hacktoberfest")))
                            "Get Involved!"
                        )
    in
    AppHeader.view
        { menuToggle = Just ToggleSidebar
        , appTitle = appTitle_
        , banner = banner
        , rightButton = Just (Button.button (ShowModal PublishModal) "Publish on Unison Share" |> Button.share)
        }


viewPerspective : Env -> Html Msg
viewPerspective env =
    case env.perspective of
        Codebase _ ->
            UI.nothing

        Namespace { codebaseHash, fqn } ->
            let
                fqnText =
                    FQN.toString fqn

                context =
                    Env.appContextToString env.appContext

                back =
                    Tooltip.tooltip
                        (Button.icon (ChangePerspective (Codebase codebaseHash)) Icon.arrowLeftUp |> Button.small |> Button.uncontained |> Button.view)
                        (Tooltip.Text ("You're currently viewing a subset of " ++ context ++ " (" ++ fqnText ++ "), click to view everything."))
                        |> Tooltip.withArrow Tooltip.End
                        |> Tooltip.view
            in
            header
                [ class "perspective" ]
                [ div [ class "namespace-slug" ] []
                , h2 [] [ text fqnText ]
                , back
                ]


viewMainSidebar : Model -> Html Msg
viewMainSidebar model =
    let
        perspective =
            model.env.perspective

        appContext =
            model.env.appContext

        changePerspectiveMsg =
            Perspective.toNamespacePerspective perspective >> ChangePerspective

        sidebarContent =
            if Perspective.isCodebasePerspective perspective && Env.isUnisonShare appContext then
                UnisonShare.SidebarContent.view changePerspectiveMsg

            else
                UI.nothing

        shareLink =
            if Env.isUnisonLocal appContext then
                a
                    [ href "https://share.unison-lang.org"
                    , rel "noopener"
                    , target "_blank"
                    ]
                    [ text "Unison Share" ]

            else
                UI.nothing
    in
    Sidebar.view
        [ viewPerspective model.env
        , sidebarContent
        , Sidebar.section
            "Namespaces and Definitions"
            [ Html.map CodebaseTreeMsg (CodebaseTree.view model.codebaseTree) ]
        , nav []
            [ a [ href "https://unisonweb.org", title "Unison website", rel "noopener", target "_blank" ] [ Icon.view Icon.unisonMark ]
            , a [ href "https://unisonweb.org/docs", rel "noopener", target "_blank" ] [ text "Docs" ]
            , a [ href "https://unisonweb.org/docs/language-reference", rel "noopener", target "_blank" ] [ text "Language Reference" ]
            , a [ href "https://unisonweb.org/community", rel "noopener", target "_blank" ] [ text "Community" ]
            , a [ onClick (ShowModal ReportBugModal) ] [ text "Report a bug" ]
            , shareLink
            , a [ class "show-help", onClick (ShowModal HelpModal) ]
                [ text "Keyboard Shortcuts"
                , KeyboardShortcut.view model.keyboardShortcut (KeyboardShortcut.single QuestionMark)
                ]
            ]
        ]


viewHelpModal : OperatingSystem -> KeyboardShortcut.Model -> Html Msg
viewHelpModal os keyboardShortcut =
    let
        viewRow label instructions =
            div
                [ class "row" ]
                [ label
                , div [ class "instructions" ] instructions
                ]

        viewInstructions label shortcuts =
            viewRow label [ KeyboardShortcut.viewShortcuts keyboardShortcut shortcuts ]

        openFinderInstructions =
            case os of
                MacOS ->
                    [ KeyboardShortcut.Chord Meta (K Key.Lower), KeyboardShortcut.Chord Ctrl (K Key.Lower), KeyboardShortcut.single ForwardSlash ]

                _ ->
                    [ KeyboardShortcut.Chord Ctrl (K Key.Lower), KeyboardShortcut.single ForwardSlash ]

        content =
            Modal.Content
                (section
                    [ class "shortcuts" ]
                    [ div [ class "shortcut-group" ]
                        [ h3 [] [ text "General" ]
                        , viewInstructions (span [] [ text "Keyboard shortcuts", UI.subtle " (this dialog)" ]) [ KeyboardShortcut.single QuestionMark ]
                        , viewInstructions (text "Open Finder") openFinderInstructions
                        , viewInstructions (text "Move focus up") [ KeyboardShortcut.single ArrowUp, KeyboardShortcut.single (K Key.Lower) ]
                        , viewInstructions (text "Move focus down") [ KeyboardShortcut.single ArrowDown, KeyboardShortcut.single (J Key.Lower) ]
                        , viewInstructions (text "Close focused definition") [ KeyboardShortcut.single (X Key.Lower) ]
                        , viewInstructions (text "Expand/Collapse focused definition") [ KeyboardShortcut.single Space ]
                        ]
                    , div [ class "shortcut-group" ]
                        [ h3 [] [ text "Finder" ]
                        , viewInstructions (text "Clear search query") [ KeyboardShortcut.single Escape ]
                        , viewInstructions (span [] [ text "Close", UI.subtle " (when search query is empty)" ]) [ KeyboardShortcut.single Escape ]
                        , viewInstructions (text "Move focus up") [ KeyboardShortcut.single ArrowUp ]
                        , viewInstructions (text "Move focus down") [ KeyboardShortcut.single ArrowDown ]
                        , viewInstructions (text "Open focused definition") [ KeyboardShortcut.single Enter ]
                        , viewRow (text "Open definition")
                            [ KeyboardShortcut.viewBase
                                [ KeyboardShortcut.viewKey os Semicolon False
                                , KeyboardShortcut.viewThen
                                , KeyboardShortcut.viewKeyBase "1-9" False
                                ]
                            ]
                        ]
                    ]
                )
    in
    Modal.modal "help-modal" CloseModal content
        |> Modal.withHeader "Keyboard shortcuts"
        |> Modal.view


githubLinkButton : String -> Html msg
githubLinkButton repo =
    Button.linkIconThenLabel ("https://github.com/" ++ repo) Icon.github repo
        |> Button.small
        |> Button.contained
        |> Button.view


viewPublishModal : Html Msg
viewPublishModal =
    let
        content =
            Modal.Content
                (section
                    []
                    [ p [ class "main" ]
                        [ text "With your Unison codebase on GitHub, open a Pull Request against "
                        , githubLinkButton "unisonweb/share"
                        , text " to list (or unlist) your project on Unison Share."
                        ]
                    , a [ class "help", href "https://www.unisonweb.org/docs/codebase-organization/#day-to-day-development-creating-and-merging-pull-requests", rel "noopener", target "_blank" ] [ text "How do I get my code on GitHub?" ]
                    ]
                )
    in
    Modal.modal "publish-modal" CloseModal content
        |> Modal.withHeader "Publish your project on Unison Share"
        |> Modal.view


viewReportBugModal : AppContext -> Html Msg
viewReportBugModal appContext =
    let
        content =
            Modal.Content
                (div []
                    [ section []
                        [ p [] [ text "We try our best, but bugs unfortunately creep through :(" ]
                        , p [] [ text "We greatly appreciate feedback and bug reports—its very helpful for providing the best developer experience when working with Unison." ]
                        ]
                    , UI.divider
                    , section [ class "actions" ]
                        [ p [] [ text "Visit our GitHub repositories to report bugs and provide feedback" ]
                        , div [ class "action" ]
                            [ githubLinkButton "unisonweb/codebase-ui"
                            , text "for reports on"
                            , strong [] [ text (Env.appContextToString appContext) ]
                            , span [ class "subtle" ] [ text "(this UI)" ]
                            ]
                        , div [ class "action" ]
                            [ githubLinkButton "unisonweb/unison"
                            , text "for reports on the"
                            , strong [] [ text "Unison Language" ]
                            , span [ class "subtle" ] [ text "(UCM)" ]
                            ]
                        ]
                    ]
                )
    in
    Modal.modal "report-bug-modal" CloseModal content
        |> Modal.withHeader "Report a Bug"
        |> Modal.view


viewModal :
    { m | env : Env, modal : Modal, keyboardShortcut : KeyboardShortcut.Model }
    -> Html Msg
viewModal model =
    case model.modal of
        NoModal ->
            UI.nothing

        FinderModal m ->
            Html.map FinderMsg (Finder.view m)

        HelpModal ->
            viewHelpModal model.env.operatingSystem model.keyboardShortcut

        PublishModal ->
            viewPublishModal

        ReportBugModal ->
            viewReportBugModal model.env.appContext


viewAppLoading : AppContext -> Html msg
viewAppLoading appContext =
    div [ id "app" ]
        [ AppHeader.view (AppHeader.appHeader (appTitle Nothing appContext))
        , Sidebar.view []
        , div [ id "main-content" ] []
        ]


viewAppError : AppContext -> Http.Error -> Html msg
viewAppError appContext error =
    let
        context =
            Env.appContextToString appContext
    in
    div [ id "app" ]
        [ AppHeader.view (AppHeader.appHeader (appTitle Nothing appContext))
        , Sidebar.view []
        , div [ id "main-content", class "app-error" ]
            [ Icon.view Icon.warn
            , p [ title (Api.errorToString error) ]
                [ text (context ++ " could not be started.") ]
            ]
        ]


view : Model -> Browser.Document Msg
view model =
    let
        title_ =
            case model.env.appContext of
                UnisonShare ->
                    "Unison Share"

                Ucm ->
                    "Unison Local"

        page =
            case model.route of
                Route.Perspective _ ->
                    Html.map PerspectiveLandingMsg
                        (PerspectiveLanding.view
                            model.env
                            model.perspectiveLanding
                        )

                Route.Definition _ _ ->
                    Html.map WorkspaceMsg (Workspace.view model.workspace)
    in
    { title = title_
    , body =
        [ div [ id "app", classList [ ( "sidebar-toggled", model.sidebarToggled ) ] ]
            [ viewAppHeader model
            , viewMainSidebar model
            , div [ id "main-content" ] [ page ]
            , viewModal model
            ]
        ]
    }
