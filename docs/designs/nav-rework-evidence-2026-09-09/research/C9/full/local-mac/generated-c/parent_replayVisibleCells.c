N_LIB_PRIVATE N_NIMCALL(void, replayVisibleCells__OOZsrcZshellZbody95nav_u2165)(tyObject_BodyNavSeatcolonObjectType___0c87LTWzqtz7zmat1zT0Kw* seat_p0, tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ origin_p1, NI base_p2) {
	tyObject_DangerSourceCachecolonObjectType___eF3OiM7VwQQb7PpdX1d3TQ* cache_1;
	NI radius_1;
	NI diameter_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_249;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_250;
	NI gridW_1;
NIM_BOOL* nimErr_;
	nimfr_("replayVisibleCells", "body_nav.nim");
{nimErr_ = nimErrorFlag();
	cache_1 = NIM_NIL;
	eqcopy___OOZsrcZshellZbody95nav_u975(&cache_1, (*seat_p0).dangerSourceCache);
	radius_1 = (*(*seat_p0).dangerGeometry).radius;
	if (nimMulInt(radius_1, ((NI)2), &TM__fw0EGWK0CbR9aJ84zaF6cBg_249)) { raiseOverflow(); goto BeforeRet_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_249), ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_250)) { raiseOverflow(); goto BeforeRet_;
	};
	diameter_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_250);
	gridW_1 = (*seat_p0).danger.gridW;
	{
		NI wordIndex_1;
		NI i_1;
		wordIndex_1 = (NI)0;
		i_1 = ((NI)0);
		{
			while (1) {
				NU64 word_1;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_251;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_263;
				if (!(i_1 < (*cache_1).words)) goto LA3;
				wordIndex_1 = i_1;
				if (nimAddInt(base_p2, wordIndex_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_251)) { raiseOverflow(); goto BeforeRet_;
				};
				if ((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_251) < 0 || (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_251) >= (*cache_1).bits.len){ raiseIndexError2((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_251),(*cache_1).bits.len-1); goto BeforeRet_;
				}
				word_1 = (*cache_1).bits.p->data[(NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_251)];
				{
					while (1) {
						NI kernelIndex_1;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_252;
						NI T6_;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_253;
						NI kernelY_1;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_254;
						NI kernelX_1;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_255;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_256;
						NI gx_1;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_257;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_258;
						NI gy_1;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_259;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_260;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_261;
						NI TM__fw0EGWK0CbR9aJ84zaF6cBg_262;
						if (!!((word_1 == 0ULL))) goto LA5;
						if (nimMulInt(wordIndex_1, ((NI)64), &TM__fw0EGWK0CbR9aJ84zaF6cBg_252)) { raiseOverflow(); goto BeforeRet_;
						};
						T6_ = (NI)0;
						T6_ = countTrailingZeroBits__OOZOOZOOZOOZOOZOnimbyZpkgsZzippyZsrcZzippyZinternal_u471(word_1);
						if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
						if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_252), T6_, &TM__fw0EGWK0CbR9aJ84zaF6cBg_253)) { raiseOverflow(); goto BeforeRet_;
						};
						kernelIndex_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_253);
						if (diameter_1 == 0){ raiseDivByZero(); goto BeforeRet_;
						}
						if (nimDivInt(kernelIndex_1, diameter_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_254)) { raiseOverflow(); goto BeforeRet_;
						};
						kernelY_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_254);
						if (nimMulInt(kernelY_1, diameter_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_255)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimSubInt(kernelIndex_1, (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_255), &TM__fw0EGWK0CbR9aJ84zaF6cBg_256)) { raiseOverflow(); goto BeforeRet_;
						};
						kernelX_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_256);
						if (nimSubInt(origin_p1.Field0, radius_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_257)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_257), kernelX_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_258)) { raiseOverflow(); goto BeforeRet_;
						};
						gx_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_258);
						if (nimSubInt(origin_p1.Field1, radius_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_259)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_259), kernelY_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_260)) { raiseOverflow(); goto BeforeRet_;
						};
						gy_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_260);
						if (nimMulInt(gy_1, gridW_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_261)) { raiseOverflow(); goto BeforeRet_;
						};
						if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_261), gx_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_262)) { raiseOverflow(); goto BeforeRet_;
						};
						if ((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_262) < 0 || (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_262) >= (*seat_p0).danger.values.len){ raiseIndexError2((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_262),(*seat_p0).danger.values.len-1); goto BeforeRet_;
						}
						if (kernelIndex_1 < 0 || kernelIndex_1 >= (*(*seat_p0).dangerGeometry).kernel.len){ raiseIndexError2(kernelIndex_1,(*(*seat_p0).dangerGeometry).kernel.len-1); goto BeforeRet_;
						}
						pluseq___OOZOOZOOZOOZOOZOnimbyZpkgsZbumpyZsrcZbumpy_u130((&(*seat_p0).danger.values.p->data[(NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_262)]), (*(*seat_p0).dangerGeometry).kernel.p->data[kernelIndex_1]);
						word_1 = (NU64)(word_1 & (NU64)((NU64)(word_1) - (NU64)(1ULL)));
					} LA5: ;
				}
				if (nimAddInt(i_1, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_263)) { raiseOverflow(); goto BeforeRet_;
				};
				i_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_263);
			} LA3: ;
		}
	}
	eqdestroy___OOZsrcZshellZbody95nav_u972(cache_1);
	}BeforeRet_: ;
	popFrame();
}