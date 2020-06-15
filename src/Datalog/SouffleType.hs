{-# LANGUAGE FlexibleInstances #-}
module Datalog.SouffleType where

import Datalog.DatalogType
import Types.Type
import Types.Program

import Text.Read
import Data.Char
import Data.List
import Data.List.Extra (dropEnd)
import Debug.Trace

getArgs 0 "" curr sofar = sofar
getArgs 0 (',':str) curr sofar = getArgs 0 (init $ drop 1 $ dropWhile isSpace str) "" (sofar ++ [curr])
getArgs i ('[':str) curr sofar = getArgs (i + 1) str (curr ++ "[") sofar
getArgs i (']':str) curr sofar = getArgs (i - 1) str (curr ++ "]") sofar
getArgs i (c:str) curr sofar = getArgs i str (curr ++ [c]) sofar
getArgs i str curr sofar = error $ show (i, str, curr, sofar)

instance Read UProgram where
    readsPrec _ ('[':input) = do
        let inner = init input
        let (sym, remaining) = span (',' /=) inner
        let next = init $ drop 1 $ dropWhile isSpace $ drop 1 remaining
        let nextArgs = getArgs 0 next "" []
        let args = map read nextArgs :: [UProgram]
        if null args
            then return (Program (PSymbol sym) AnyT, "")
            else return (Program (PApp sym args) AnyT, "")
    readsPrec _ _ = []

instance PrintType SouffleType where
    writeType vars (SouffleType (ScalarT (TypeVarT _ id) _)) = if id `Set.member` vars then map toUpper id else "_"
    writeType vars (SouffleType (ScalarT (DatatypeT dt args _) _)) = printf "[\"%s\", %s]" (replaceId tyclassPrefix "" dt) argStrs
        where
            argStrs = foldr (\a acc -> printf "[%s, %s]" (writeType vars a) acc) "nil" args
    writeType vars (SouffleType (FunctionT _ tArg tRes)) = writeType vars (SouffleType $ ScalarT (DatatypeT "Fun" [tArg, tRes] []) ())

    writeArg name t@(SouffleType tArg) = printf "inh(%s, \"%s\")" (writeType (typeVarsOf tArg) t) name
