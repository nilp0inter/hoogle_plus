module Encoder.CBCEnc() where

import Numeric.Limp.Program
import Numeric.Limp.Solvers.Cbc
import Data.Maybe
import Data.List
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Set (Set)
import qualified Data.Set as Set
import Control.Monad.State
import Control.Lens

import Encoder.CBCTypes
import Encoder.ConstraintEncoder (FunctionCode(..))
import qualified Encoder.ConstraintEncoder as CE
import Types.Common
import Types.Abstract
import Synquid.Pretty

addPlaceVar :: AbstractSkeleton -> Int -> Encoder ()
addPlaceVar p t = do
    pvar <- gets $ view (variables . place2variable)
    vnbr <- gets $ view (variables . variableNb)
    let p2v = HashMap.insert (p, t) vnbr pvar
    let nonneg = lowerZ vnbr
    unless (HashMap.member (p, t) pvar) $ do
        modify $ set (variables . place2variable) p2v
        modify $ over (variables . variableNb) (+ 1)
        modify $ over (constraints . varBounds) (nonneg :)

addTransitionVar :: Id -> Int -> Encoder ()
addTransitionVar tr t = do
    tvar <- gets $ view (variables . trans2variable)
    tnbr <- gets $ view (variables . transitionNb)
    let tr2v = HashMap.insert (tr, t) tnbr tvar
    let bin = binary tnbr
    unless (HashMap.member (tr, t) tvar) $ do
        modify $ set (variables . trans2variable) tr2v
        modify $ over (variables . transitionNb) (+ 1)
        modify $ over (constraints . varBounds) (bin :)

setInitialState :: [AbstractSkeleton] -> [AbstractSkeleton] -> Encoder () 
setInitialState inputs places = do
    let nonInputs = filter (`notElem` inputs) places
    let inputCounts = map (\t -> (head t, length t)) (group $ sort inputs)
    let nonInputCounts = map (, 0) nonInputs
    mapM_ (uncurry assignToken) (inputCounts ++ nonInputCounts)
    where
        assignToken p c = do
            placeMap <- gets $ view (variables . place2variable)
            let pvar = z1 $ findVariable "place2variable" (p, 0) placeMap
            let tokens = con (Z c)
            let eq = pvar :== tokens
            modify $ over (constraints . optionalConstraints) (eq :)

setFinalState :: AbstractSkeleton -> [AbstractSkeleton] -> Encoder ()
setFinalState ret places = do
    let nonRets = filter ((/=) ret) places
    let nonRetCounts = map (, 0) nonRets
    let counts = (ret, 1) : nonRetCounts
    mapM_ (uncurry assignToken) counts
    where
        assignToken p c = do
            placeMap <- gets $ view (variables . place2variable)
            t <- gets $ view (increments . loc)
            let pvar = z1 $ findVariable "place2variable" (p, t) placeMap
            let tokens = con (Z c)
            let eq = pvar :== tokens
            modify $ over (constraints . finalConstraints) (eq :)

disableTransitions :: [Id] -> Int -> Encoder ()
disableTransitions trs t = mapM_ disableTransitionAt trs
    where
        disableTransitionAt tr = do
            transMap <- gets $ view (variables . trans2variable)
            let trVar = z1 $ findVariable "trans2variable" (tr, t) transMap
            let eq = trVar :== c0
            modify $ over (constraints . persistConstraints) (eq :)

transPrecondition :: FunctionCode -> Int -> Encoder ()
transPrecondition (FunctionCode name [] params rets) t = do
    transMap <- gets $ view (variables . trans2variable)
    -- accumulate counting for parameters and return types
    let pcnt = map (\l -> (head l, length l)) (group (sort params))
    let pmap = HashMap.fromList pcnt
    let trVar = z1 $ findVariable "trans2variable" (name, t) transMap
    mapM_ (uncurry $ getPrecondition trVar) pmap
    where
        getPrecondition trVar p c = do
            placeMap <- gets $ view (variables . place2variable)
            let before = z1 $ findVariable "place2variable" (p, t) placeMap
            let sat = (trVar .* c) :<= before
            modify $ over (constraints . persistConstraints) (sat :)

transPostcondition :: AbstractSkeleton -> Int -> Encoder ()
transPostcondition p t = do
    t2tr <- gets $ view (variables . type2transition)
    signatures <- gets $ view (increments . encodedSigs)
    placeMap <- gets $ view (variables . place2variable)
    let before = z1 $ findVariable "place2variable" (p, t) placeMap
    let after = z1 $ findVariable "place2variable" (p, t + 1) placeMap
    let transSet = HashMap.lookupDefault Set.empty p t2tr
    let selectedSigs = filter (\(FunctionCode tid _ _ _) -> tid `Set.member` transSet) signatures
    let changes = map getCounts selectedSigs
    let changeLinear = LZ (zip changes $ repeat (Z 1)) (Z 0)
    let mkChange = after :== (before .+. changeLinear)
    modify $ over (constraints . optionalConstraints) (mkChange :)
    where
        getCounts (FunctionCode tr _ params rets) = do
            transMap <- gets $ view (variables . trans2variable)
            -- accumulate counting for parameters and return types
            let pcnt = map (\l -> (head l, length l)) (group (sort params))
            let pmap = HashMap.fromList pcnt
            let rmap = foldl' (\acc t -> HashMap.insertWith (+) t (-1) acc) pmap rets
            let rcnt = HashMap.toList rmap
            let cnt = findVariable "token change" p rcnt
            let trVar = z1 $ findVariable "trans2variable" (tr, t) transMap
            return $ cnt *. trVar

-- maybe we can change this into nonoverlapping transitions
-- otherwise they are allowed to be execute parallelly
singleTransition :: Int -> Encoder ()
singleTransition t = do
    signatures <- gets $ view (increments . encodedSigs)
    transMap <- gets $ view (variables . trans2variable)
    let trVars = map (\(FunctionCode tr _ _ _) ->
        z1 $ findVariable "trans2variable" (tr, t) transMap) signatures
    let sumOne = (LZ (zip trVars $ repeat (Z 1)) (Z 0)) :== c1
    modify $ over (constraints . optionalConstraints) (sumOne :)

mustFireTransitions :: Encoder ()
mustFireTransitions = do
    must <- gets $ view (refinements . mustFirers)
    mapM_ fireTransition (HashMap.toList must)
    where
        fireTransition (_, tids) = do
            l <- gets $ view (increments . loc)
            transMap <- gets $ view (variables . trans2variable)
            let trVars = map (\k -> findVariable "trans2variable" k transMap) (zip tids (repeat l))
            let fire = (LZ (zip trVars $ repeat (Z 1)) (Z 0)) :>= c1
            modify $ over (constraints . optionalConstraints) (fire :)

encoderInit :: CBCState
            -> Int
            -> [AbstractSkeleton]
            -> [AbstractSkeleton]
            -> [FunctionCode]
            -> IO CBCState
encoderInit encoderState len inputs rets sigs =
    execStateT (do
        modify $ set (increments . loc) len
        modify $ set (refinements . returnTyps) rets
        createEncoder inputs (head rets) sigs) encoderState

-- | create a new encoder in z3
createEncoder :: [AbstractSkeleton] -> AbstractSkeleton -> [FunctionCode] -> Encoder ()
createEncoder inputs ret sigs = do
    modify $ set (increments . encodedSigs) sigs
    ty2tr <- gets $ view (variables . type2transition)
    l <- gets $ view (increments . loc)
    let places = HashMap.keys ty2tr
    let transIds = Set.toList $ Set.unions $ HashMap.elems ty2tr

    -- create the type variables
    mapM_ (uncurry addPlaceVar) [(a, t) | a <- places, t <- [0..l]]
    -- create the transition variables
    mapM_ (uncurry addTransitionVar) [(tr, t) | tr <- transIds, t <- [0..(l - 1)]]
    -- add constraints for pre- and post-conditions
    mapM_ (uncurry transPrecondition) [(tr, t) | tr <- transIds, t <- [0..(l - 1)]]
    mapM_ (uncurry transPostcondition) [(a, t) | a <- places, t <- [0..(l - 1)]]
    -- only one transition can be fired at each time step
    mapM_ singleTransition [0..(l - 1)]
    -- add constraints for arguments
    mustFireTransitions
    -- set initial and final state for solver
    setInitialState inputs places
    setFinalState ret places

encoderSolve :: CBCState -> IO ([Id], CBCState)
encoderSolve = runStateT solveAndGetModel

solveAndGetModel :: Encoder [Id]
solveAndGetModel = do
    l <- gets $ view (increments . loc)
    Constraints p o f b bds <- gets $ view constraints
    transMap <- gets $ view (variables . trans2variable)
    let trVars = HashMap.elems transMap
    let obj = LZ (zip trVars $ repeat (Z 1)) (Z 0)
    let constraint = foldl (foldr (.&&)) CTrue [p, o, f, b]
    let problem = minimise obj constraint bds
    case solve problem of
        Left err -> liftIO (print err) >> return []
        Right ass -> do
            let transAssignment = map (\(k, i) -> (k, zOf ass i)) (HashMap.toList transMap)
            let transSelected = filter ((==) (Z 1) . snd) transAssignment
            let transitions = map fst transSelected
            let currTrans = foldr (addAssignment transMap) CTrue transAssignment
            modify $ set (increments . block) (neg currTrans)
            return $ map fst $ sortOn snd transitions
    where
        addAssignment transMap (k, v) acc =
            let i = findVariable "trans2variable" k transMap
             in (z1 i :== v) .&& acc

-- optimize the optional constraints here:
-- we only need to change the must firers and noTransitionTokens and final states
encoderInc :: [AbstractSkeleton] -> [AbstractSkeleton] -> Encoder ()
encoderInc inputs rets = do
    persists <- gets $ view (constraints . persistConstraints)
    modify $ over (increments . loc) (+ 1)
    modify $ set (refinements . returnTyps) rets
    modify $ set constraints ( emptyConstraints { _persistConstraints = persists })
    ty2tr <- gets $ view (variables . type2transition)
    l <- gets $ view (increments . loc)
    sigs <- gets $ view (increments . encodedSigs)
    toRemove <- gets $ view (refinements . disabledTrans)
    let places = HashMap.keys ty2tr
    let transitions = Set.toList $ Set.unions $ HashMap.elems ty2tr
    let newTransitions = [(tr, l - 1) | tr <- sigs ]
    let newPlaces = [(a, l) | a <- places ]

    -- add new place, transition and timestamp variables
    mapM_ (uncurry addPlaceVar) newPlaces
    -- disable transitions at the new timestamp
    disableTransitions toRemove (l - 1)
    -- refine the precondition
    mapM_ (uncurry transPrecondition) newTransitions
    -- refine the postcondition
    mapM_ (uncurry transPostcondition) [(a, l - 1) | a <- places]
    -- single transition can be fired at each time step
    mapM_ singleTransition [0..(l - 1)]
    -- refine the must firers
    mustFireTransitions
    -- set new initial and final state
    setInitialState inputs places
    setFinalState (head rets) places

encoderRefine :: SplitInfo 
              -> [AbstractSkeleton] 
              -> [AbstractSkeleton] 
              -> [FunctionCode] 
              -> Encoder ()
encoderRefine info inputs rets newSigs = do
    {- update the abstraction level -}
    modify $ over (refinements . disabledTrans) (++ removedTrans info)
    modify $ over (increments . encodedSigs) (++ newSigs)
    modify $ set (refinements . returnTyps) rets
    modify $ set (constraints . optionalConstraints) []
    modify $ set (constraints . finalConstraints) []

    {- operation on places -}
    l <- gets $ view (increments . loc)
    t2tr <- gets $ view (variables . type2transition)
    sigs <- gets $ view (increments . encodedSigs)
    let newPlaceIds = newPlaces info
    let newTransIds = newTrans info
    let currPlaces = HashMap.keys t2tr
    let newTrans = [(functionName tr, t) | t <- [0..(l-1)], tr <- newSigs ]
    let allTrans = [(functionName tr, t) | t <- [0..(l-1)], tr <- sigs ]

    -- add new place variables
    mapM_ (uncurry addPlaceVar) [(a, i) | a <- newPlaceIds, i <- [0..l]]
    -- add new transition variables
    mapM_ (uncurry addTransitionVar) newTrans
    -- refine the precondition constraints
    mapM_ (uncurry transPrecondition) newTrans
    -- refine the postcondition constraints
    mapM_ (uncurry transPostcondition) [(a, i) | a <- currPlaces, i <- [0..(l-1)]]
    -- disable splitted transitions
    mapM_ (disableTransitions (removedTrans info)) [0..(l-1)]
    -- single transition can be fired at each time step
    mapM_ singleTransition [0..(l - 1)]
    -- refine the must firers
    mustFireTransitions
    -- set new initial and final state
    setInitialState inputs currPlaces
    setFinalState (head rets) currPlaces
