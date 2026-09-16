static N_INLINE(void, addVisibleCell__OOZsrcZshellZbody95nav_u2077)(tyObject_BodyNavSeatcolonObjectType___0c87LTWzqtz7zmat1zT0Kw* seat_p0, tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ origin_p1, NF32* kernel_p2, NI kernel_p2Len_0, NI kernelRadius_p3, NI gx_p4, NI gy_p5) {
	tyObject_DangerSourceCachecolonObjectType___eF3OiM7VwQQb7PpdX1d3TQ* cache_1;
	NI32 colontmpD_;
	NI index_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_251;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_252;
	NI diameter_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_253;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_254;
	NI kernelX_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_255;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_256;
	NI kernelY_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_257;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_258;
	NF32 weight_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_259;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_260;
	NI slot_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_261;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_262;
	tyObject_DangerSourceEntry__Q9arhEVQ9bgP16CdlIu9b9a9bDQ T20_;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_263;
NIM_BOOL* nimErr_;
	nimfr_("addVisibleCell", "body_nav.nim");
{nimErr_ = nimErrorFlag();
	cache_1 = NIM_NIL;
	colontmpD_ = (NI32)0;
	{
		NIM_BOOL T4_;
		NIM_BOOL T5_;
		NIM_BOOL T6_;
		T4_ = (NIM_BOOL)0;
		T5_ = (NIM_BOOL)0;
		T6_ = (NIM_BOOL)0;
		T6_ = (gx_p4 < ((NI)0));
		if (T6_) goto LA7_;
		T6_ = ((*seat_p0).danger.gridW <= gx_p4);
LA7_: ;
		T5_ = T6_;
		if (T5_) goto LA8_;
		T5_ = (gy_p5 < ((NI)0));
LA8_: ;
		T4_ = T5_;
		if (T4_) goto LA9_;
		T4_ = ((*seat_p0).danger.gridH <= gy_p5);
LA9_: ;
		if (!T4_) goto LA10_;
		eqdestroy___OOZsrcZshellZbody95nav_u976(cache_1);
		goto BeforeRet_;
	}
LA10_: ;
	if (nimMulInt(gy_p5, (*seat_p0).danger.gridW, &TM__fw0EGWK0CbR9aJ84zaF6cBg_251)) { raiseOverflow(); goto LA1_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_251), gx_p4, &TM__fw0EGWK0CbR9aJ84zaF6cBg_252)) { raiseOverflow(); goto LA1_;
	};
	index_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_252);
	{
		if (index_1 < 0 || index_1 >= (*seat_p0).dangerWorkspace.visited.len){ raiseIndexError2(index_1,(*seat_p0).dangerWorkspace.visited.len-1); goto LA1_;
		}
		if (!((*seat_p0).dangerWorkspace.visited.p->data[index_1] == (*seat_p0).dangerWorkspace.visitGeneration)) goto LA14_;
		eqdestroy___OOZsrcZshellZbody95nav_u976(cache_1);
		goto BeforeRet_;
	}
LA14_: ;
	if (index_1 < 0 || index_1 >= (*seat_p0).dangerWorkspace.visited.len){ raiseIndexError2(index_1,(*seat_p0).dangerWorkspace.visited.len-1); goto LA1_;
	}
	(*seat_p0).dangerWorkspace.visited.p->data[index_1] = (*seat_p0).dangerWorkspace.visitGeneration;
	if (nimMulInt(kernelRadius_p3, ((NI)2), &TM__fw0EGWK0CbR9aJ84zaF6cBg_253)) { raiseOverflow(); goto LA1_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_253), ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_254)) { raiseOverflow(); goto LA1_;
	};
	diameter_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_254);
	if (nimSubInt(gx_p4, origin_p1.Field0, &TM__fw0EGWK0CbR9aJ84zaF6cBg_255)) { raiseOverflow(); goto LA1_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_255), kernelRadius_p3, &TM__fw0EGWK0CbR9aJ84zaF6cBg_256)) { raiseOverflow(); goto LA1_;
	};
	kernelX_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_256);
	if (nimSubInt(gy_p5, origin_p1.Field1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_257)) { raiseOverflow(); goto LA1_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_257), kernelRadius_p3, &TM__fw0EGWK0CbR9aJ84zaF6cBg_258)) { raiseOverflow(); goto LA1_;
	};
	kernelY_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_258);
	if (nimMulInt(kernelY_1, diameter_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_259)) { raiseOverflow(); goto LA1_;
	};
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_259), kernelX_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_260)) { raiseOverflow(); goto LA1_;
	};
	if ((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_260) < 0 || (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_260) >= kernel_p2Len_0){ raiseIndexError2((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_260),kernel_p2Len_0-1); goto LA1_;
	}
	weight_1 = kernel_p2[(NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_260)];
	{
		if (!(weight_1 == 0.0f)) goto LA18_;
		eqdestroy___OOZsrcZshellZbody95nav_u976(cache_1);
		goto BeforeRet_;
	}
LA18_: ;
	eqcopy___OOZsrcZshellZbody95nav_u979(&cache_1, (*seat_p0).dangerSourceCache);
	slot_1 = (*seat_p0).dangerRecordSlot;
	if (nimMulInt(slot_1, (*cache_1).capacity, &TM__fw0EGWK0CbR9aJ84zaF6cBg_261)) { raiseOverflow(); goto LA1_;
	};
	if ((NU)(slot_1) > (NU)(63)){ raiseIndexError2(slot_1, 63); goto LA1_;
	}
	if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_261), ((NI) ((*cache_1).slots[(slot_1)- 0].length)), &TM__fw0EGWK0CbR9aJ84zaF6cBg_262)) { raiseOverflow(); goto LA1_;
	};
	if ((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_262) < 0 || (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_262) >= (*cache_1).entries.len){ raiseIndexError2((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_262),(*cache_1).entries.len-1); goto LA1_;
	}
	if ((index_1) < ((NI32)(-2147483647 -1)) || (index_1) > ((NI32)2147483647)){ raiseRangeErrorI(index_1, ((NI32)(-2147483647 -1)), ((NI32)2147483647)); goto LA1_;
	}
	colontmpD_ = ((NI32) (index_1));
	T20_.gridIndex = colontmpD_;
	T20_.weight = weight_1;
	(*cache_1).entries.p->data[(NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_262)] = T20_;
	if ((NU)(slot_1) > (NU)(63)){ raiseIndexError2(slot_1, 63); goto LA1_;
	}
	if (nimAddInt((*cache_1).slots[(slot_1)- 0].length, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_263)) { raiseOverflow(); goto LA1_;
	};
	if (TM__fw0EGWK0CbR9aJ84zaF6cBg_263 < (-2147483647 -1) || TM__fw0EGWK0CbR9aJ84zaF6cBg_263 > 2147483647){ raiseOverflow(); goto LA1_;
	}
	(*cache_1).slots[(slot_1)- 0].length = (NI32)(TM__fw0EGWK0CbR9aJ84zaF6cBg_263);
	if (index_1 < 0 || index_1 >= (*seat_p0).danger.values.len){ raiseIndexError2(index_1,(*seat_p0).danger.values.len-1); goto LA1_;
	}
	pluseq___OOZOOZOOZOOZOOZOnimbyZpkgsZbumpyZsrcZbumpy_u130((&(*seat_p0).danger.values.p->data[index_1]), weight_1);
	{
		LA1_:;
	}
	{
		eqdestroy___OOZsrcZshellZbody95nav_u976(cache_1);
	}
	if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
	}BeforeRet_: ;
	popFrame();
}